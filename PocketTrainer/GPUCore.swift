// GPUCore.swift —— 同一个网络的「GPU 版」(MPSGraph 自动求导) + 「模拟系统打断」
import Foundation
import Metal
import MetalPerformanceShadersGraph

/// GPU 训练一步：和 CPUNet.step 做同一件事，但用 Metal GPU，快得多。
final class GPUNet {
    let H: Int
    private let queue: MTLCommandQueue
    private let gdev: MPSGraphDevice
    private let g = MPSGraph()
    private var x, y, w1, b1, w2, b2: MPSGraphTensor
    private var outs: [MPSGraphTensor] = []

    init?(hidden: Int, lr: Float) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        H = hidden; queue = q; gdev = MPSGraphDevice(mtlDevice: dev)
        func ns(_ a: [Int]) -> [NSNumber] { a.map { NSNumber(value: $0) } }
        x = g.placeholder(shape: ns([batchSize, featureDim]), dataType: .float32, name: "x")
        y = g.placeholder(shape: ns([batchSize, numClasses]), dataType: .float32, name: "y")
        w1 = g.placeholder(shape: ns([featureDim, hidden]), dataType: .float32, name: "w1")
        b1 = g.placeholder(shape: ns([hidden]), dataType: .float32, name: "b1")
        w2 = g.placeholder(shape: ns([hidden, numClasses]), dataType: .float32, name: "w2")
        b2 = g.placeholder(shape: ns([numClasses]), dataType: .float32, name: "b2")
        // 前向：ReLU(x·W1+b1)·W2+b2 → softmax → 交叉熵
        let a = g.reLU(with: g.addition(g.matrixMultiplication(primary: x, secondary: w1, name: nil), b1, name: nil), name: nil)
        let logits = g.addition(g.matrixMultiplication(primary: a, secondary: w2, name: nil), b2, name: nil)
        let p = g.softMax(with: logits, axis: 1, name: nil)
        let logp = g.logarithm(with: g.addition(p, g.constant(1e-9, dataType: .float32), name: nil), name: nil)
        let loss = g.negative(with: g.mean(of: g.reductionSum(with: g.multiplication(y, logp, name: nil), axes: [1], name: nil), axes: [0, 1], name: nil), name: nil)
        // 反向：MPSGraph 自动求导；SGD：参数 −= lr × 梯度
        let params = [w1, b1, w2, b2]
        let grads = g.gradients(of: loss, with: params, name: nil)
        let lrT = g.constant(Double(lr), dataType: .float32)
        outs = params.map { g.subtraction($0, g.multiplication(grads[$0]!, lrT, name: nil), name: nil) }
    }

    func step(_ w: Weights, _ xb: [Float], _ yb: [Float]) -> Weights? {
        func ns(_ a: [Int]) -> [NSNumber] { a.map { NSNumber(value: $0) } }
        func td(_ arr: [Float], _ shape: [Int]) -> MPSGraphTensorData {
            MPSGraphTensorData(device: gdev, data: arr.withUnsafeBufferPointer { Data(buffer: $0) }, shape: ns(shape), dataType: .float32)
        }
        func read(_ d: MPSGraphTensorData, _ n: Int) -> [Float] {
            var o = [Float](repeating: 0, count: n); d.mpsndarray().readBytes(&o, strideBytes: nil); return o
        }
        let r = g.run(with: queue,
                      feeds: [x: td(xb, [batchSize, featureDim]), y: td(yb, [batchSize, numClasses]),
                              w1: td(w.w1, [featureDim, H]), b1: td(w.b1, [H]), w2: td(w.w2, [H, numClasses]), b2: td(w.b2, [numClasses])],
                      targetTensors: outs, targetOperations: nil)
        guard let o1 = r[outs[0]], let o2 = r[outs[1]], let o3 = r[outs[2]], let o4 = r[outs[3]] else { return nil }
        return Weights(w1: read(o1, featureDim * H), b1: read(o2, H), w2: read(o3, H * numClasses), b2: read(o4, numClasses))
    }
}

/// 「模拟系统打断」：在训练的同一时刻，往 GPU 提交一个跑不完的超长任务。
/// iOS 的看门狗会把它掐掉（"GPU hang"），而和它同时在 GPU 上的训练步可能被连累，
/// 得到「看起来正常、其实是错的」结果 —— 不报任何错误。这是我们在真机上实测到的现象。
/// 注意：被系统标记后，同一次启动里再提交的超长任务会被忽略，所以每次启动只能演示一次。
enum Interruption {
    private(set) static var usedThisLaunch = false
    private static var status = "not fired"
    static var lastStatus: String { status }
    private(set) static var firedAt: Date?
    private(set) static var doneAt: Date?      // 系统掐掉超长任务的时刻（用来看它和训练的先后）

    static func markUsed() { usedThisLaunch = true }   // 测「GPU 限时」也会让系统标记本次启动

    static func fire() {
        guard !usedThisLaunch, let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void hang(device float *o [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]]) {
            float a = float(i);
            for (uint k = 0; k < n; k++) { a = fma(a, 1.0000001f, 1e-7f); }   // 循环 20 亿次
            o[i] = a;
        }
        """
        guard let lib = try? dev.makeLibrary(source: src, options: nil), let fn = lib.makeFunction(name: "hang"),
              let pso = try? dev.makeComputePipelineState(function: fn), let buf = dev.makeBuffer(length: 4096 * 4),
              let cb = q.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        usedThisLaunch = true
        var n: UInt32 = 2_000_000_000
        enc.setComputePipelineState(pso); enc.setBuffer(buf, offset: 0, index: 0); enc.setBytes(&n, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: 4096, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        status = "submitted"; firedAt = Date()
        cb.addCompletedHandler { c in
            doneAt = Date()
            status = (c.error as NSError?).map { "error \($0.code): \($0.localizedDescription)" } ?? "finished ok"
        }
        cb.commit()   // 只提交，不等待
    }
}
