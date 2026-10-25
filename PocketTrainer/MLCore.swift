// MLCore.swift —— 数据 + 两层神经网络的「CPU 版」（影子校验用它，也用它算准确率）
// 网络：2048 个特征 → H 个隐藏单元(ReLU) → 10 类，损失 = 交叉熵，优化 = 普通 SGD。
import Foundation
import Accelerate

let featureDim = 2048   // 每张照片已被预训练的 ResNet50 压成 2048 个数字
let numClasses = 10     // CIFAR-10 的 10 个类别
let batchSize = 128     // 每一步看 128 张照片

let classNames = ["airplane", "car", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]

/// 网络的全部参数
struct Weights {
    var w1: [Float], b1: [Float], w2: [Float], b2: [Float]
}

/// 数据集：App 里存的是 float16（省空间，28MB），读进来转回 float32
final class Dataset {
    static let shared = Dataset()
    let trainX: [Float], trainY: [UInt8], testX: [Float], testY: [UInt8]
    var trainCount: Int { trainY.count }
    var testCount: Int { testY.count }

    /// 别的数据（比如表格）自己给数据：特征已经补到 2048 维
    init(trainX: [Float], trainY: [UInt8], testX: [Float], testY: [UInt8]) {
        self.trainX = trainX; self.trainY = trainY; self.testX = testX; self.testY = testY
    }

    private init() {
        func half(_ name: String) -> [Float] {
            let d = try! Data(contentsOf: Bundle.main.url(forResource: name, withExtension: "f16")!)
            var h = [Float16](repeating: 0, count: d.count / 2)
            _ = h.withUnsafeMutableBytes { d.copyBytes(to: $0) }
            return h.map { Float($0) }
        }
        func bytes(_ name: String) -> [UInt8] {
            [UInt8](try! Data(contentsOf: Bundle.main.url(forResource: name, withExtension: "u8")!))
        }
        trainX = half("train_x"); trainY = bytes("train_y")
        testX = half("test_x");   testY = bytes("test_y")
    }
}

/// 固定种子的小随机数（同一个种子 → 每次初始权重和批次顺序完全一样，方便对比）
struct LCG {
    var s: UInt64
    init(seed: UInt64) { s = 0x9E3779B97F4A7C15 &* (seed + 1) }
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
    /// -1 ~ 1 之间的小数
    mutating func uniform() -> Float { Float(Int64(bitPattern: next() >> 11) % 2000001) / 1000000.0 - 1.0 }
}

/// 一次训练的「剧本」：初始权重 + 每个 epoch 的照片顺序（由种子决定）
struct Plan {
    let initial: Weights
    let order: [[Int]]
    let stepsPerEpoch: Int
    var totalSteps: Int { stepsPerEpoch * order.count }

    init(seed: UInt64, hidden H: Int, epochs: Int, trainCount N: Int) {
        var g = LCG(seed: seed)
        func randn(_ n: Int, _ scale: Float) -> [Float] { (0..<n).map { _ in (g.uniform() + g.uniform() + g.uniform()) * scale } }
        let w1 = randn(featureDim * H, 1 / Float(featureDim).squareRoot())
        let w2 = randn(H * numClasses, 1 / Float(H).squareRoot())
        initial = Weights(w1: w1, b1: [Float](repeating: 0, count: H), w2: w2, b2: [Float](repeating: 0, count: numClasses))
        var all: [[Int]] = []
        for _ in 0..<epochs {
            var idx = Array(0..<N)
            for i in stride(from: N - 1, to: 0, by: -1) { idx.swapAt(i, Int((g.next() >> 33) % UInt64(i + 1))) }  // 洗牌
            all.append(idx)
        }
        order = all
        stepsPerEpoch = N / batchSize
    }

    /// 取第 step 步要用的 128 张照片：特征 x，和 one-hot 标签 y
    func batch(_ step: Int, _ data: Dataset) -> (x: [Float], y: [Float]) {
        let idx = order[step / stepsPerEpoch], o = (step % stepsPerEpoch) * batchSize
        var x = [Float](repeating: 0, count: batchSize * featureDim)
        var y = [Float](repeating: 0, count: batchSize * numClasses)
        for k in 0..<batchSize {
            let i = idx[o + k]
            x.replaceSubrange(k * featureDim..<(k + 1) * featureDim, with: data.trainX[i * featureDim..<(i + 1) * featureDim])
            y[k * numClasses + Int(data.trainY[i])] = 1
        }
        return (x, y)
    }
}

/// 「影子」：用 CPU 手写的反向传播，算同一步的新权重
struct CPUNet {
    let H: Int, lr: Float
    private var D: Int { featureDim }
    private var C: Int { numClasses }
    private var B: Int { batchSize }

    func step(_ w: Weights, _ x: [Float], _ y: [Float]) -> Weights {
        let D = D, C = C, B = B, H = H
        // ---- 前向：z1 = x·W1 + b1，a = ReLU(z1)，z2 = a·W2 + b2
        var z1 = [Float](repeating: 0, count: B * H)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(B), Int32(H), Int32(D), 1, x, Int32(D), w.w1, Int32(H), 0, &z1, Int32(H))
        for r in 0..<B { for c in 0..<H { z1[r * H + c] += w.b1[c] } }
        var a = z1
        for i in 0..<a.count where a[i] < 0 { a[i] = 0 }
        var z2 = [Float](repeating: 0, count: B * C)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(B), Int32(C), Int32(H), 1, a, Int32(H), w.w2, Int32(C), 0, &z2, Int32(C))
        // ---- softmax + 交叉熵的梯度：d2 = (概率 − 标签) / B
        var d2 = [Float](repeating: 0, count: B * C)
        for r in 0..<B {
            var m: Float = -1e30
            for c in 0..<C { z2[r * C + c] += w.b2[c]; m = max(m, z2[r * C + c]) }
            var sum: Float = 0
            for c in 0..<C { let e = expf(z2[r * C + c] - m); d2[r * C + c] = e; sum += e }
            for c in 0..<C { d2[r * C + c] = (d2[r * C + c] / sum - y[r * C + c]) / Float(B) }
        }
        // ---- 反向
        var gw2 = [Float](repeating: 0, count: H * C), gb2 = [Float](repeating: 0, count: C)
        cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(H), Int32(C), Int32(B), 1, a, Int32(H), d2, Int32(C), 0, &gw2, Int32(C))
        for r in 0..<B { for c in 0..<C { gb2[c] += d2[r * C + c] } }
        var da = [Float](repeating: 0, count: B * H)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(B), Int32(H), Int32(C), 1, d2, Int32(C), w.w2, Int32(C), 0, &da, Int32(H))
        for i in 0..<da.count where z1[i] <= 0 { da[i] = 0 }   // ReLU 的导数
        var gw1 = [Float](repeating: 0, count: D * H), gb1 = [Float](repeating: 0, count: H)
        cblas_sgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(D), Int32(H), Int32(B), 1, x, Int32(D), da, Int32(H), 0, &gw1, Int32(H))
        for r in 0..<B { for c in 0..<H { gb1[c] += da[r * H + c] } }
        // ---- SGD：权重 −= 学习率 × 梯度
        var n = w
        for i in 0..<n.w1.count { n.w1[i] -= lr * gw1[i] }
        for i in 0..<n.b1.count { n.b1[i] -= lr * gb1[i] }
        for i in 0..<n.w2.count { n.w2[i] -= lr * gw2[i] }
        for i in 0..<n.b2.count { n.b2[i] -= lr * gb2[i] }
        return n
    }

    /// 前向：m 张照片 → 10 类的得分（给评估和算损失用，不改权重）
    func logits(_ w: Weights, _ xs: [Float], _ m: Int) -> [Float] {
        var z1 = [Float](repeating: 0, count: m * H)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(m), Int32(H), Int32(D), 1, xs, Int32(D), w.w1, Int32(H), 0, &z1, Int32(H))
        for r in 0..<m { for c in 0..<H { z1[r * H + c] = max(0, z1[r * H + c] + w.b1[c]) } }
        var z2 = [Float](repeating: 0, count: m * C)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(m), Int32(C), Int32(H), 1, z1, Int32(H), w.w2, Int32(C), 0, &z2, Int32(C))
        for r in 0..<m { for c in 0..<C { z2[r * C + c] += w.b2[c] } }
        return z2
    }

    /// 一行得分的交叉熵损失：log(sum(exp(z))) − z[正确类]
    private func rowLoss(_ z: ArraySlice<Float>, _ label: Int) -> Double {
        let m = z.max()!
        return Double(m) + log(z.map { Double(expf($0 - m)) }.reduce(0, +)) - Double(z[z.startIndex + label])
    }

    /// 在测试集（模型从没见过的 2000 张）上的准确率(0~1)和平均损失
    func evaluate(_ w: Weights, _ data: Dataset) -> (acc: Double, loss: Double) {
        let D = D, C = C, NT = data.testCount
        var ok = 0, loss = 0.0
        for k in stride(from: 0, to: NT, by: 100) {
            let m = min(100, NT - k)
            let z2 = logits(w, Array(data.testX[k * D..<(k + m) * D]), m)
            for r in 0..<m {
                let row = z2[r * C..<(r + 1) * C]
                let label = Int(data.testY[k + r])
                if row.firstIndex(of: row.max()!)! - row.startIndex == label { ok += 1 }
                loss += rowLoss(row, label)
            }
        }
        return (Double(ok) / Double(NT), loss / Double(NT))
    }

    func accuracy(_ w: Weights, _ data: Dataset) -> Double { evaluate(w, data).acc }

    /// 当前这一批 128 张训练照片的平均损失（Run 输出里的 loss）
    func batchLoss(_ w: Weights, _ x: [Float], _ y: [Float]) -> Double {
        let z2 = logits(w, x, B)
        var s = 0.0
        for r in 0..<B { s += rowLoss(z2[r * C..<(r + 1) * C], (0..<C).first { y[r * C + $0] == 1 } ?? 0) }
        return s / Double(B)
    }
}

/// 影子校验的尺子：GPU 算出的「更新量」和 CPU 的「更新量」方向差多少（1 − 余弦相似度）。
/// 正常 < 1e-6；被系统打断污染后会变成 0.1 ~ 2。
func updateMismatch(_ new: [Float], _ ref: [Float], _ old: [Float]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for k in 0..<new.count {
        let a = Double(new[k] - old[k]), b = Double(ref[k] - old[k])
        dot += a * b; na += a * a; nb += b * b
    }
    return 1 - dot / max((na * nb).squareRoot(), 1e-30)
}
