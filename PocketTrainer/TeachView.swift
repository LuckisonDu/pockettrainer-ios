// TeachView.swift —— 加分项：「Teach it your own photos」
// 选 3 类、每类约 15 张你自己的照片 → 用 Core ML 的 ResNet50 把每张照片变成 2048 个数字（特征）→
// 在手机上训练一个很小的分类器（2048 → 3 类）→ 再拿一张新照片让它猜。全部离线、全部在 CPU 上，几秒钟。
import SwiftUI
import PhotosUI
import CoreML

/// 把照片变成 2048 个特征数字
enum FeatureExtractor {
    static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "ResNet50Features", withExtension: "mlmodelc") else { return nil }
        return try? MLModel(contentsOf: url)
    }()

    // ---- 用户可以换成自己从 Hugging Face 下载并编译的 Core ML 特征模型（输入图片、输出一个向量）
    static let customKey = "teachModel"
    static var customName: String? { UserDefaults.standard.string(forKey: customKey).map { ($0 as NSString).lastPathComponent } }
    private static var customCache: (path: String, model: MLModel)?
    private static func custom() -> MLModel? {
        guard let rel = UserDefaults.standard.string(forKey: customKey) else { return nil }
        if let c = customCache, c.path == rel { return c.model }
        guard let m = try? MLModel(contentsOf: Store.docs.appendingPathComponent(rel)) else { return nil }
        customCache = (rel, m); return m
    }
    private static func customFeatures(_ m: MLModel, _ cg: CGImage) -> [Float]? {
        guard let (name, d) = m.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }), let ic = d.imageConstraint,
              let fv = try? MLFeatureValue(cgImage: cg, constraint: ic, options: nil),
              let out = try? m.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: fv])),
              let arr = out.featureNames.sorted().compactMap({ out.featureValue(for: $0)?.multiArrayValue }).first else { return nil }
        var v = (0..<arr.count).map { Float(truncating: arr[$0]) }
        let norm = max(v.map { $0 * $0 }.reduce(0, +).squareRoot(), 1e-6)
        v = v.map { $0 / norm }
        return v
    }

    static func features(of image: UIImage) -> [Float]? {
        if let m = custom(), let cg = image.cgImage { return customFeatures(m, cg) }
        guard let model, let cg = image.cgImage else { return nil }
        // 1. 缩成 224×224（先按短边放大再居中裁掉多余部分），取出 RGB 像素
        let S = 224
        var px = [UInt8](repeating: 0, count: S * S * 4)
        guard let ctx = CGContext(data: &px, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let scale = CGFloat(S) / CGFloat(min(cg.width, cg.height))
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        ctx.draw(cg, in: CGRect(x: (CGFloat(S) - w) / 2, y: (CGFloat(S) - h) / 2, width: w, height: h))
        // 2. 排成 [1,3,224,224]，数值 0~1（模型里面自己会减均值、除标准差）
        guard let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: S), NSNumber(value: S)], dataType: .float32) else { return nil }
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * S * S)
        for i in 0..<S * S { for c in 0..<3 { p[c * S * S + i] = Float(px[i * 4 + c]) / 255 } }
        // 3. 跑模型
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": arr])),
              let f = out.featureValue(for: "features")?.multiArrayValue else { return nil }
        var v = (0..<f.count).map { Float(truncating: f[$0]) }
        let norm = max(v.map { $0 * $0 }.reduce(0, +).squareRoot(), 1e-6)   // 长度归一，训练更稳
        v = v.map { $0 / norm }
        return v
    }
}

/// 很小的分类器：2048 → 3 类（softmax 回归），在 CPU 上训练
struct TinyHead {
    let dim: Int                  // 特征个数：内置 ResNet50 是 2048，换了别的模型就不一样
    var w: [Float], b = [Float](repeating: 0, count: 3)
    init(dim: Int) { self.dim = dim; w = [Float](repeating: 0, count: dim * 3) }

    func probs(_ x: [Float]) -> [Float] {
        var z = (0..<3).map { c in b[c] + (0..<dim).reduce(Float(0)) { $0 + x[$1] * w[$1 * 3 + c] } }
        let m = z.max()!; z = z.map { expf($0 - m) }; let s = z.reduce(0, +)
        return z.map { $0 / s }
    }

    mutating func train(_ xs: [[Float]], _ ys: [Int], epochs: Int = 300, lr: Float = 2.0) {
        for _ in 0..<epochs {
            var gw = [Float](repeating: 0, count: w.count), gb = [Float](repeating: 0, count: 3)
            for (x, y) in zip(xs, ys) {
                var p = probs(x); p[y] -= 1            // 梯度 = 概率 − 标签
                for c in 0..<3 { gb[c] += p[c]; for i in 0..<dim { gw[i * 3 + c] += x[i] * p[c] } }
            }
            let n = Float(xs.count)
            for i in 0..<w.count { w[i] -= lr * gw[i] / n }
            for c in 0..<3 { b[c] -= lr * gb[c] / n }
        }
    }
}

struct TeachView: View {
    @State private var names = ["Class 1", "Class 2", "Class 3"]
    @State private var picks: [[PhotosPickerItem]] = [[], [], []]
    @State private var feats: [[[Float]]] = [[], [], []]
    @State private var head: TinyHead?
    @State private var trainAcc = 0.0
    @State private var testPick: PhotosPickerItem?
    @State private var answer = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Teach it your own photos").font(.title2.bold())
                HStack {
                    Text(FeatureExtractor.customName.map { tr("Feature extractor: %@", $0) } ?? tr("Feature extractor: built-in ResNet50")).font(.caption.bold())
                    Spacer()
                    if FeatureExtractor.customName != nil { Button("Use the built-in extractor") { UserDefaults.standard.removeObject(forKey: FeatureExtractor.customKey); feats = [[], [], []]; head = nil } .font(.caption) }
                }
                Text("Pick about 15 photos for each of 3 things (for example: mug, shoe, plant). Then train and test with a new photo.")
                    .font(.footnote).foregroundColor(.secondary)
                ForEach(0..<3, id: \.self) { k in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $names[k]).textFieldStyle(.roundedBorder)
                        PhotosPicker(selection: $picks[k], maxSelectionCount: 20, matching: .images) {
                            Label(tr("Choose photos (%ld ready)", feats[k].count), systemImage: "photo.on.rectangle")
                        }.buttonStyle(.bordered)
                    }
                    .onChange(of: picks[k]) { items in Task { await load(k, items) } }
                }
                Button { train() } label: { Text("Train on my photos").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(busy || feats.contains { $0.count < 3 })
                if head != nil {
                    Text(tr("Learned! Accuracy on your training photos: %.0f%%", trainAcc * 100)).font(.subheadline.bold()).foregroundColor(.green)
                    PhotosPicker(selection: $testPick, matching: .images) { Label("Test with a new photo", systemImage: "questionmark.circle") }
                        .buttonStyle(.bordered)
                        .onChange(of: testPick) { item in Task { await test(item) } }
                }
                if !answer.isEmpty { Text(answer).font(.headline) }
                if busy { ProgressView() }
            }.padding(16)
        }
    }

    private func image(_ item: PhotosPickerItem) async -> UIImage? {
        guard let d = try? await item.loadTransferable(type: Data.self) else { return nil }
        return UIImage(data: d)
    }

    private func load(_ k: Int, _ items: [PhotosPickerItem]) async {
        busy = true; head = nil; answer = ""
        var out: [[Float]] = []
        for it in items { if let img = await image(it), let f = FeatureExtractor.features(of: img) { out.append(f) } }
        feats[k] = out; busy = false
    }

    private func train() {
        let xs = feats.flatMap { $0 }
        let ys = feats.enumerated().flatMap { k, f in [Int](repeating: k, count: f.count) }
        var h = TinyHead(dim: xs[0].count); h.train(xs, ys)
        trainAcc = Double(zip(xs, ys).filter { x, y in h.probs(x).firstIndex(of: h.probs(x).max()!) == y }.count) / Double(xs.count)
        head = h; answer = ""
    }

    private func test(_ item: PhotosPickerItem?) async {
        guard let item, let h = head, let img = await image(item), let f = FeatureExtractor.features(of: img) else { return }
        let p = h.probs(f), best = p.firstIndex(of: p.max()!)!
        answer = tr("It thinks: %@ (%ld%% sure)", names[best], Int(p[best] * 100))
    }
}

/// 测试用（启动参数 --teach-selftest）：用程序画的三类简单图片走一遍「特征 → 训练 → 预测」，结果写进 Documents/teach_selftest.json
enum TeachSelfTest {
    static func run() {
        func img(_ k: Int, _ seed: Int) -> UIImage {   // 三类：红色竖条 / 绿色横条 / 蓝色圆点，位置随机
            var g = LCG(seed: UInt64(seed * 3 + k))
            return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { c in
                UIColor(white: 0.9, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
                let o = CGFloat((g.uniform() + 1) * 60)
                [UIColor.red, UIColor.green, UIColor.blue][k].setFill()
                switch k {
                case 0: c.fill(CGRect(x: 40 + o, y: 0, width: 50, height: 200))
                case 1: c.fill(CGRect(x: 0, y: 30 + o, width: 300, height: 40))
                default: c.cgContext.fillEllipse(in: CGRect(x: 40 + o, y: 30 + o / 2, width: 90, height: 90))
                }
            }
        }
        var xs: [[Float]] = [], ys: [Int] = [], tx: [[Float]] = [], ty: [Int] = []
        let t0 = Date()
        for k in 0..<3 { for s in 0..<15 { if let f = FeatureExtractor.features(of: img(k, s)) { xs.append(f); ys.append(k) } }
                         for s in 100..<105 { if let f = FeatureExtractor.features(of: img(k, s)) { tx.append(f); ty.append(k) } } }
        var h = TinyHead(dim: xs.first?.count ?? featureDim); h.train(xs, ys)
        let ok = zip(tx, ty).filter { x, y in let p = h.probs(x); return p.firstIndex(of: p.max()!) == y }.count
        let r: [String: Any] = ["featureDim": xs.first?.count ?? 0, "train": xs.count, "test": tx.count, "testCorrect": ok,
                                "seconds": -t0.timeIntervalSinceNow, "modelLoaded": FeatureExtractor.model != nil]
        try? JSONSerialization.data(withJSONObject: r).write(to: Store.docs.appendingPathComponent("teach_selftest.json"))
    }
}
