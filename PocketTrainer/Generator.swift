// Generator.swift —— 在手机上训练一个小型「图片生成」模型：条件变分自编码器（CVAE）。
// 输入一张 28×28 图和它的类别 → 编码成 2 个数（「笔迹风格」）→ 再用这 2 个数 + 类别画回原图。训练好以后，
// 只给类别 + 2 个随机数，它就能画出一张「新」的这一类图片（比如新的手写数字 7）。
// 全部在手机 CPU 上算（Accelerate），前向 / 反向 / Adam 都是手写的，不依赖 Python。
// 说明：本文件由 AI（Claude）编写，须在国会 AI 披露里写明；学生要能讲清楚「编码 → 随机 → 解码」这三步。
import Foundation
import Accelerate
import UIKit

struct CVAE {
    static let D = 28 * 28, C = 10, Z = 2
    let H: Int
    // 参数（行优先）：W1 [(D+C)×H]、Wmu/Wlv [H×Z]、W3 [(Z+C)×H]、W4 [H×D]
    var W1: [Float], b1: [Float], Wmu: [Float], bmu: [Float], Wlv: [Float], blv: [Float], W3: [Float], b3: [Float], W4: [Float], b4: [Float]

    init(hidden H: Int, seed: UInt64) {
        self.H = H
        var g = LCG(seed: seed)
        func randn(_ n: Int, _ s: Float) -> [Float] { (0..<n).map { _ in (g.uniform() + g.uniform() + g.uniform()) * s } }
        let D = Self.D, C = Self.C, Z = Self.Z
        W1 = randn((D + C) * H, 1 / Float(D + C).squareRoot()); b1 = [Float](repeating: 0, count: H)
        Wmu = randn(H * Z, 1 / Float(H).squareRoot()); bmu = [Float](repeating: 0, count: Z)
        Wlv = randn(H * Z, 0.1 / Float(H).squareRoot()); blv = [Float](repeating: 0, count: Z)
        W3 = randn((Z + C) * H, 1 / Float(Z + C).squareRoot()); b3 = [Float](repeating: 0, count: H)
        W4 = randn(H * D, 1 / Float(H).squareRoot()); b4 = [Float](repeating: 0, count: D)
    }

    var params: [[Float]] { [W1, b1, Wmu, bmu, Wlv, blv, W3, b3, W4, b4] }
    mutating func setParams(_ p: [[Float]]) { W1 = p[0]; b1 = p[1]; Wmu = p[2]; bmu = p[3]; Wlv = p[4]; blv = p[5]; W3 = p[6]; b3 = p[7]; W4 = p[8]; b4 = p[9] }

    // MARK: 小工具

    /// C[m×n] = A[m×k] · B[k×n]（transA/transB 时按转置读）
    static func mm(_ A: [Float], _ B: [Float], _ m: Int, _ n: Int, _ k: Int, ta: Bool = false, tb: Bool = false) -> [Float] {
        var C = [Float](repeating: 0, count: m * n)
        cblas_sgemm(CblasRowMajor, ta ? CblasTrans : CblasNoTrans, tb ? CblasTrans : CblasNoTrans, Int32(m), Int32(n), Int32(k), 1,
                    A, Int32(ta ? m : k), B, Int32(tb ? k : n), 0, &C, Int32(n))
        return C
    }
    static func addBias(_ X: inout [Float], _ b: [Float], rows: Int) { let n = b.count; for r in 0..<rows { for c in 0..<n { X[r * n + c] += b[c] } } }
    static func colSum(_ X: [Float], rows: Int, cols: Int) -> [Float] { var s = [Float](repeating: 0, count: cols); for r in 0..<rows { for c in 0..<cols { s[c] += X[r * cols + c] } }; return s }
    static func concat(_ A: [Float], _ a: Int, _ B: [Float], _ b: Int, rows: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rows * (a + b))
        for r in 0..<rows { for c in 0..<a { out[r * (a + b) + c] = A[r * a + c] }; for c in 0..<b { out[r * (a + b) + a + c] = B[r * b + c] } }
        return out
    }
    static func gauss(_ g: inout LCG) -> Float {
        let u1 = max(Float(g.next() >> 40) / Float(1 << 24), 1e-7), u2 = Float(g.next() >> 40) / Float(1 << 24)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    // MARK: 训练一步：返回（重建损失, KL 损失, 各参数的梯度）

    func lossAndGrads(x X: [Float], y Y: [Float], batch B: Int, rng: inout LCG) -> (recon: Float, kl: Float, grads: [[Float]]) {
        let D = Self.D, C = Self.C, Z = Self.Z, H = self.H, fb = Float(B)
        // 前向
        let XY = Self.concat(X, D, Y, C, rows: B)
        var A1 = Self.mm(XY, W1, B, H, D + C); Self.addBias(&A1, b1, rows: B)
        let H1 = A1.map { max(0, $0) }
        var MU = Self.mm(H1, Wmu, B, Z, H); Self.addBias(&MU, bmu, rows: B)
        var LV = Self.mm(H1, Wlv, B, Z, H); Self.addBias(&LV, blv, rows: B)
        LV = LV.map { min(max($0, -8), 8) }
        let EPS = (0..<(B * Z)).map { _ in Self.gauss(&rng) }
        let STD = LV.map { exp(0.5 * $0) }
        let ZS = (0..<(B * Z)).map { MU[$0] + STD[$0] * EPS[$0] }
        let ZY = Self.concat(ZS, Z, Y, C, rows: B)
        var A3 = Self.mm(ZY, W3, B, H, Z + C); Self.addBias(&A3, b3, rows: B)
        let H3 = A3.map { max(0, $0) }
        var A4 = Self.mm(H3, W4, B, D, H); Self.addBias(&A4, b4, rows: B)
        // 损失：每张图的 BCE（逐像素求和）+ KL，按批平均
        var recon: Float = 0, kl: Float = 0
        var dA4 = [Float](repeating: 0, count: B * D)
        for i in 0..<(B * D) {
            let a = A4[i], x = X[i]
            recon += (a > 0 ? a + log1p(exp(-a)) : log1p(exp(a))) - x * a
            dA4[i] = (1 / (1 + exp(-a)) - x) / fb
        }
        for i in 0..<(B * Z) { kl += -0.5 * (1 + LV[i] - MU[i] * MU[i] - exp(LV[i])) }
        recon /= fb; kl /= fb
        // 反向
        let gW4 = Self.mm(H3, dA4, H, D, B, ta: true), gb4 = Self.colSum(dA4, rows: B, cols: D)
        var dA3 = Self.mm(dA4, W4, B, H, D, tb: true)
        for i in 0..<(B * H) where A3[i] <= 0 { dA3[i] = 0 }
        let gW3 = Self.mm(ZY, dA3, Z + C, H, B, ta: true), gb3 = Self.colSum(dA3, rows: B, cols: H)
        let dZY = Self.mm(dA3, W3, B, Z + C, H, tb: true)
        var dMU = [Float](repeating: 0, count: B * Z), dLV = [Float](repeating: 0, count: B * Z)
        for r in 0..<B { for c in 0..<Z {
            let i = r * Z + c, dz = dZY[r * (Z + C) + c]
            dMU[i] = dz + MU[i] / fb
            dLV[i] = dz * EPS[i] * 0.5 * STD[i] + 0.5 * (exp(LV[i]) - 1) / fb
        } }
        let gWmu = Self.mm(H1, dMU, H, Z, B, ta: true), gbmu = Self.colSum(dMU, rows: B, cols: Z)
        let gWlv = Self.mm(H1, dLV, H, Z, B, ta: true), gblv = Self.colSum(dLV, rows: B, cols: Z)
        var dH1 = Self.mm(dMU, Wmu, B, H, Z, tb: true)
        let dH1b = Self.mm(dLV, Wlv, B, H, Z, tb: true)
        for i in 0..<(B * H) { dH1[i] = A1[i] > 0 ? dH1[i] + dH1b[i] : 0 }
        let gW1 = Self.mm(XY, dH1, D + C, H, B, ta: true), gb1 = Self.colSum(dH1, rows: B, cols: H)
        return (recon, kl, [gW1, gb1, gWmu, gbmu, gWlv, gblv, gW3, gb3, gW4, gb4])
    }

    // MARK: 画图：给类别和 2 个随机数 → 28×28 灰度（0~255）

    func generate(label: Int, count: Int, rng: inout LCG) -> [[UInt8]] {
        let C = Self.C, Z = Self.Z
        var Y = [Float](repeating: 0, count: count * C); for r in 0..<count { Y[r * C + label] = 1 }
        let ZS = (0..<(count * Z)).map { _ in Self.gauss(&rng) }
        return decode(ZS, Y, count).map { row in row.map { UInt8(clamping: Int(($0 * 255).rounded())) } }
    }
    /// 编码 → 取均值 → 解码（「重建」：看模型记住了什么）
    func reconstruct(_ X: [Float], label: [Int]) -> [[UInt8]] {
        let D = Self.D, C = Self.C, Z = Self.Z, B = label.count
        var Y = [Float](repeating: 0, count: B * C); for r in 0..<B { Y[r * C + label[r]] = 1 }
        var A1 = Self.mm(Self.concat(X, D, Y, C, rows: B), W1, B, H, D + C); Self.addBias(&A1, b1, rows: B)
        var MU = Self.mm(A1.map { max(0, $0) }, Wmu, B, Z, H); Self.addBias(&MU, bmu, rows: B)
        return decode(MU, Y, B).map { row in row.map { UInt8(clamping: Int(($0 * 255).rounded())) } }
    }
    /// 指定风格数字（每张 Z 个）画同一类：风格地图用
    func decodeStyles(_ zs: [Float], label: Int) -> [[UInt8]] {
        let C = Self.C, B = zs.count / Self.Z
        var Y = [Float](repeating: 0, count: B * C); for r in 0..<B { Y[r * C + label] = 1 }
        return decode(zs, Y, B).map { row in row.map { UInt8(clamping: Int(($0 * 255).rounded())) } }
    }
    private func decode(_ ZS: [Float], _ Y: [Float], _ B: Int) -> [[Float]] {
        let D = Self.D, C = Self.C, Z = Self.Z
        var A3 = Self.mm(Self.concat(ZS, Z, Y, C, rows: B), W3, B, H, Z + C); Self.addBias(&A3, b3, rows: B)
        var A4 = Self.mm(A3.map { max(0, $0) }, W4, B, D, H); Self.addBias(&A4, b4, rows: B)
        return (0..<B).map { r in (0..<D).map { 1 / (1 + exp(-A4[r * D + $0])) } }
    }

    // MARK: 存 / 读（[H 4 字节][各参数 float32]）

    func pack() -> Data {
        var d = Data(); var h = UInt32(H); withUnsafeBytes(of: &h) { d.append(contentsOf: $0) }
        for p in params { p.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
        return d
    }
    static func unpack(_ d: Data) -> CVAE? {
        guard d.count > 4 else { return nil }
        let H = Int(d.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        var m = CVAE(hidden: H, seed: 1)
        let sizes = m.params.map(\.count)
        guard d.count == 4 + sizes.reduce(0, +) * 4 else { return nil }
        var off = 4, out: [[Float]] = []
        for n in sizes {
            var a = [Float](repeating: 0, count: n)
            _ = a.withUnsafeMutableBytes { d.subdata(in: (d.startIndex + off)..<(d.startIndex + off + n * 4)).copyBytes(to: $0) }
            out.append(a); off += n * 4
        }
        m.setParams(out); return m
    }
}

/// Adam 优化器（每个参数一份一阶 / 二阶动量）
struct Adam {
    var lr: Float, b1: Float = 0.9, b2: Float = 0.999, eps: Float = 1e-8, t = 0
    var m: [[Float]], v: [[Float]]
    init(shapes: [Int], lr: Float) { self.lr = lr; m = shapes.map { [Float](repeating: 0, count: $0) }; v = m }
    mutating func step(_ p: inout [[Float]], _ g: [[Float]]) {
        t += 1
        let c1 = 1 - pow(b1, Float(t)), c2 = 1 - pow(b2, Float(t))
        for k in p.indices { for i in p[k].indices {
            let gi = g[k][i]
            m[k][i] = b1 * m[k][i] + (1 - b1) * gi
            v[k][i] = b2 * v[k][i] + (1 - b2) * gi * gi
            p[k][i] -= lr * (m[k][i] / c1) / ((v[k][i] / c2).squareRoot() + eps)
        } }
    }
}

/// 生成器项目的训练：在后台线程训 CVAE，界面看这里的 @Published。每轮存一次模型（原子写），并画一排「它现在会画什么」。
final class GenTrainer: ObservableObject {
    static let shared = GenTrainer()
    @Published var running = false
    @Published var step = 0
    @Published var totalSteps = 0
    @Published var log: [String] = []
    @Published var lossPoints: [LossPoint] = []
    @Published var preview: [[UInt8]] = []      // 每个类别一张（固定的随机数），每轮更新：看它从一团噪声慢慢学会画
    @Published var project = ""
    @Published var saved = 0                    // 每存一次模型 +1，结果页据此重新读

    static func modelURL(_ project: String) -> URL { ProjectStore.dir(project).appendingPathComponent("checkpoints/generator.bin") }
    static func infoURL(_ project: String) -> URL { ProjectStore.dir(project).appendingPathComponent("checkpoints/generator.json") }
    static func load(_ project: String) -> CVAE? { (try? Data(contentsOf: modelURL(project))).flatMap(CVAE.unpack) }
    static func info(_ project: String) -> [String: Any]? { (try? Data(contentsOf: infoURL(project))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    /// 一批图片 → (像素 0~1, 类别 one-hot)
    static func batch(_ im: ProjectData.Images, _ idx: some Collection<Int>) -> (x: [Float], y: [Float]) {
        let D = CVAE.D, C = CVAE.C
        var x = [Float](repeating: 0, count: idx.count * D), y = [Float](repeating: 0, count: idx.count * C)
        for (r, j) in idx.enumerated() {
            for k in 0..<D { x[r * D + k] = Float(im.pixels[j * D + k]) / 255 }
            y[r * C + min(Int(im.labels[j]), C - 1)] = 1
        }
        return (x, y)
    }

    func start(project: String, hidden: Int, lr: Double, epochs: Int, seed: UInt64) throws {
        guard !running else { return }
        guard let im = ProjectData.images(project) else { throw ProjectData.Failure(errorDescription: tr("Choose a picture dataset first (Data → Choose data).")) }
        let BS = 64, (train, test) = ProjectData.split(im.count)
        let perEpoch = max(1, train.count / BS), total = perEpoch * epochs
        let dataTitle = ProjectData.source(project)?.title ?? ""
        self.project = project; running = true; step = 0; totalSteps = total; lossPoints = []; preview = []
        log = [tr("Run started: %ld epochs, learning rate %.3g, %ld hidden units", epochs, lr, hidden),
               tr("Training a picture generator on %ld pictures (%@)", train.count, dataTitle)]
        UIApplication.shared.isIdleTimerDisabled = true
        let valIdx = Array(test.prefix(256))
        Task.detached(priority: .userInitiated) { [self] in
            var net = CVAE(hidden: hidden, seed: seed)
            var opt = Adam(shapes: net.params.map(\.count), lr: Float(lr))
            var rng = LCG(seed: seed), order = train, s = 0
            let (vx, vy) = GenTrainer.batch(im, valIdx)
            let t0 = Date()
            var last: (Float, Float) = (0, 0)
            for ep in 0..<epochs {
                for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, Int((rng.next() >> 33) % UInt64(i + 1))) }
                var sum: Float = 0
                for b in 0..<perEpoch {
                    autoreleasepool {
                        let (xb, yb) = GenTrainer.batch(im, order[(b * BS)..<((b + 1) * BS)])
                        let (rc, kl, g) = net.lossAndGrads(x: xb, y: yb, batch: BS, rng: &rng)
                        var p = net.params; opt.step(&p, g); net.setParams(p)
                        sum += rc + kl; s += 1
                    }
                    let now = s
                    if now % 5 == 0 { DispatchQueue.main.async { self.step = now } }
                }
                // 每轮：在没参与训练的图片上量损失（固定随机数，曲线可比），存模型，画一排预览
                var vr = LCG(seed: 99)
                let (vrc, vkl, _) = net.lossAndGrads(x: vx, y: vy, batch: valIdx.count, rng: &vr)
                last = (vrc, vkl)
                var pr = LCG(seed: 5)
                let pv = (0..<min(CVAE.C, im.classes.count)).map { net.generate(label: $0, count: 1, rng: &pr)[0] }
                try? FileManager.default.createDirectory(at: GenTrainer.modelURL(project).deletingLastPathComponent(), withIntermediateDirectories: true)
                try? net.pack().write(to: GenTrainer.modelURL(project), options: .atomic)
                let tl = Double(sum / Float(perEpoch)), vl = Double(vrc + vkl), now = s, e = ep + 1
                DispatchQueue.main.async {
                    self.step = now; self.preview = pv; self.saved += 1
                    self.lossPoints.append(LossPoint(step: now, train: tl, val: vl))
                    self.log.append(tr("Epoch %ld/%ld  loss: %.1f  val_loss: %.1f", e, epochs, tl, vl))
                }
            }
            let secs = -t0.timeIntervalSinceNow
            var info = utsname(); uname(&info)
            let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
            let meta: [String: Any] = ["data": ProjectData.dataKey(project), "dataTitle": dataTitle, "pictures": train.count, "epochs": epochs, "hidden": hidden,
                                       "learningRate": lr, "steps": s, "seconds": secs, "valRecon": Double(last.0), "valKL": Double(last.1),
                                       "device": machine, "date": Date().timeIntervalSince1970]
            try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: GenTrainer.infoURL(project), options: .atomic)
            ProjectData.stampTrained(project)
            DispatchQueue.main.async {
                self.running = false; self.saved += 1
                self.log.append(tr("Done: %ld steps in %.1f s on this phone. Open the Result tab to see what it draws.", s, secs))
                UIApplication.shared.isIdleTimerDisabled = testKeepAwake
            }
        }
    }
}
