// CoreMLExport.swift —— 把 App 里训练好的两层网络（2048 → H(ReLU) → 10）导出成 Core ML 模型，并能在手机上编译、加载、验证。
// 不用 Python、不用 coremltools：Core ML 的模型文件（.mlmodel）是一种 protobuf 数据，这里手写最小的编码器直接写出来。
// 同时导出 float32 的 weights.safetensors（PyTorch 可直接读，名字对应 nn.Sequential(Linear, ReLU, Linear)）和 meta.json，
// 这样「手机 → PyTorch」的回路是通的。模型文件是数据，不是代码：下载后在手机上用 MLModel.compileModel 编译再加载是 App Store 允许的。
// 说明：本文件由 AI（Claude）编写，须在国会 AI 披露里写明；学生要能讲清「Core ML 模型文件是什么」。
import Foundation
import CoreML
import Accelerate

/// 最小的 protobuf 编码器（只需要：varint、长度前缀字节串、packed float）
struct PBWriter {
    var data = Data()
    mutating func varint(_ v: UInt64) { var x = v; while x >= 0x80 { data.append(UInt8(x & 0x7f) | 0x80); x >>= 7 }; data.append(UInt8(x)) }
    mutating func tag(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }
    mutating func uint(_ field: Int, _ v: UInt64) { tag(field, 0); varint(v) }
    mutating func int(_ field: Int, _ v: Int64) { tag(field, 0); varint(UInt64(bitPattern: v)) }
    mutating func bool(_ field: Int, _ v: Bool) { uint(field, v ? 1 : 0) }
    mutating func bytes(_ field: Int, _ d: Data) { tag(field, 2); varint(UInt64(d.count)); data.append(d) }
    mutating func string(_ field: Int, _ s: String) { bytes(field, Data(s.utf8)) }
    mutating func message(_ field: Int, _ build: (inout PBWriter) -> Void) { var w = PBWriter(); build(&w); bytes(field, w.data) }
    mutating func packedFloats(_ field: Int, _ v: [Float]) {
        var d = Data(count: v.count * 4)
        d.withUnsafeMutableBytes { p in v.withUnsafeBytes { src in p.copyMemory(from: src) } }   // 小端 float32
        bytes(field, d)
    }
}

enum CoreMLExport {
    static let inputName = "features", outputName = "scores"

    /// Core ML 的内积层权重是 [输出, 输入] 行优先；我们的 w1 是 [输入 D][隐藏 H]、w2 是 [H][类别 C]，所以要转置。
    static func transposed(_ a: [Float], rows: Int, cols: Int) -> [Float] {
        var out = [Float](repeating: 0, count: a.count)
        vDSP_mtrans(a, 1, &out, 1, vDSP_Length(cols), vDSP_Length(rows))
        return out
    }

    /// 写出 .mlmodel 的字节（NeuralNetwork：两层 InnerProduct + ReLU；输入 features [2048] float32，输出 scores [10] 未归一化得分）
    static func mlmodelData(_ w: Weights, hidden H: Int, input D: Int = featureDim, classes C: Int = numClasses, note: String = "") -> Data {
        func featureDesc(_ name: String, _ n: Int, _ desc: String) -> (inout PBWriter) -> Void {
            return { f in
                f.string(1, name); f.string(2, desc)
                f.message(3) { t in t.message(5) { a in a.int(1, Int64(n)); a.uint(2, 65568) } }      // FeatureType.multiArrayType(5)：shape=[n]，dataType=FLOAT32(65568)
            }
        }
        func weightParams(_ v: [Float]) -> (inout PBWriter) -> Void { return { p in p.packedFloats(1, v) } }   // WeightParams.floatValue(1)
        func inner(name: String, input: String, output: String, inC: Int, outC: Int, weights: [Float], bias: [Float]) -> (inout PBWriter) -> Void {
            return { l in
                l.string(1, name); l.string(2, input); l.string(3, output)
                l.message(140) { p in                                                               // NeuralNetworkLayer.innerProduct(140)
                    p.uint(1, UInt64(inC)); p.uint(2, UInt64(outC)); p.bool(10, true)               // inputChannels, outputChannels, hasBias
                    p.message(20, weightParams(weights)); p.message(21, weightParams(bias))
                }
            }
        }
        var m = PBWriter()
        m.int(1, 1)                                                                                   // specificationVersion = 1（iOS 11 起都能读）
        m.message(2) { d in                                                                           // ModelDescription
            d.message(1, featureDesc(inputName, D, "Photo features (2048 numbers from a pretrained ResNet50)"))
            d.message(10, featureDesc(outputName, C, "Raw class scores (10 classes)"))
            d.message(100) { md in md.string(2, note.isEmpty ? "Trained on-device with PocketTrainer" : note) }   // Metadata.shortDescription(2)
        }
        m.message(500) { nn in                                                                        // Model.neuralNetwork(500)
            nn.message(1, inner(name: "fc1", input: inputName, output: "h", inC: D, outC: H, weights: transposed(w.w1, rows: D, cols: H), bias: w.b1))
            nn.message(1) { l in l.string(1, "relu"); l.string(2, "h"); l.string(3, "a"); l.message(130) { a in a.message(10) { _ in } } }   // activation(130) → ReLU(10)
            nn.message(1, inner(name: "fc2", input: "a", output: outputName, inC: H, outC: C, weights: transposed(w.w2, rows: H, cols: C), bias: w.b2))
        }
        return m.data
    }

    /// safetensors：8 字节小端头长度 + JSON 头 + 原始 float32。键名对应 PyTorch nn.Sequential(Linear(D,H), ReLU(), Linear(H,C)) 的 state_dict。
    static func safetensorsData(_ w: Weights, hidden H: Int, input D: Int = featureDim, classes C: Int = numClasses) -> Data {
        let tensors: [(String, [Int], [Float])] = [
            ("0.weight", [H, D], transposed(w.w1, rows: D, cols: H)), ("0.bias", [H], w.b1),
            ("2.weight", [C, H], transposed(w.w2, rows: H, cols: C)), ("2.bias", [C], w.b2)]
        var header: [String: Any] = ["__metadata__": ["format": "pt", "producer": "PocketTrainer"]]
        var off = 0; var body = Data()
        for (name, shape, v) in tensors {
            let n = v.count * 4
            header[name] = ["dtype": "F32", "shape": shape, "data_offsets": [off, off + n]]
            var d = Data(count: n); d.withUnsafeMutableBytes { p in v.withUnsafeBytes { s in p.copyMemory(from: s) } }
            body.append(d); off += n
        }
        var js = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data()
        while js.count % 8 != 0 { js.append(0x20) }                                                   // 头按 8 字节对齐（用空格补）
        var out = Data(); var len = UInt64(js.count).littleEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }; out.append(js); out.append(body)
        return out
    }

    /// 读 App 存的 .ckpt（[步数 4 字节][w1][b1][w2][b2][FNV 校验 8 字节]）；隐藏单元数 H 由文件大小反推。校验不对返回 nil。
    static func loadCheckpoint(_ url: URL) -> (weights: Weights, hidden: Int, step: Int)? {
        guard let d = try? Data(contentsOf: url), d.count > 20 else { return nil }
        let body = d.prefix(d.count - 8)
        let stored = d.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard Store.fnv(Data(body)) == stored else { return nil }
        let nf = (body.count - 4) / 4, D = featureDim, C = numClasses
        guard nf > C, (nf - C) % (D + 1 + C) == 0 else { return nil }
        let H = (nf - C) / (D + 1 + C)
        let step = Int(body.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        var off = 4
        func take(_ n: Int) -> [Float] {
            var o = [Float](repeating: 0, count: n)
            _ = o.withUnsafeMutableBytes { body.subdata(in: (body.startIndex + off)..<(body.startIndex + off + n * 4)).copyBytes(to: $0) }
            off += n * 4; return o
        }
        return (Weights(w1: take(D * H), b1: take(H), w2: take(H * C), b2: take(C)), H, step)
    }

    struct Result { var dir: URL, modelURL: URL, safetensorsURL: URL, metaURL: URL, hidden: Int }

    /// 导出到 dir（model.mlmodel + weights.safetensors + meta.json）
    static func export(_ w: Weights, hidden H: Int, to dir: URL, note: String = "") throws -> Result {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mURL = dir.appendingPathComponent("model.mlmodel"), sURL = dir.appendingPathComponent("weights.safetensors"), jURL = dir.appendingPathComponent("meta.json")
        try mlmodelData(w, hidden: H, note: note).write(to: mURL, options: .atomic)
        try safetensorsData(w, hidden: H).write(to: sURL, options: .atomic)
        let meta: [String: Any] = ["architecture": "Sequential(Linear(\(featureDim),\(H)), ReLU(), Linear(\(H),\(numClasses)))", "input": inputName, "output": outputName,
                                   "classes": classNames, "input_dim": featureDim, "hidden": H, "weights": "weights.safetensors (float32, PyTorch Linear layout [out, in])"]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: jURL, options: .atomic)
        return Result(dir: dir, modelURL: mURL, safetensorsURL: sURL, metaURL: jURL, hidden: H)
    }

    /// CPU 前向（与 App 里训练用的 CPU 版同一个公式）：返回每行的 10 个得分
    static func cpuScores(_ w: Weights, hidden H: Int, x: [Float], rows n: Int) -> [Float] {
        var z1 = [Float](repeating: 0, count: n * H)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(H), Int32(featureDim), 1, x, Int32(featureDim), w.w1, Int32(H), 0, &z1, Int32(H))
        for r in 0..<n { for c in 0..<H { z1[r * H + c] = max(0, z1[r * H + c] + w.b1[c]) } }
        var z2 = [Float](repeating: 0, count: n * numClasses)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(n), Int32(numClasses), Int32(H), 1, z1, Int32(H), w.w2, Int32(numClasses), 0, &z2, Int32(numClasses))
        for r in 0..<n { for c in 0..<numClasses { z2[r * numClasses + c] += w.b2[c] } }
        return z2
    }

    struct Verification { var rows: Int, coreMLAccuracy: Double, cpuAccuracy: Double, maxAbsDiff: Float, sameTop1: Int, computeUnits: String }

    /// 在手机上：编译导出的 .mlmodel → 加载 → 对测试照片逐张预测，与 CPU 前向对比
    static func verify(_ w: Weights, hidden H: Int, modelURL: URL, data: Dataset, rows: Int = 2000, units: MLComputeUnits = .cpuOnly) throws -> Verification {
        let compiled = try MLModel.compileModel(at: modelURL)
        let cfg = MLModelConfiguration(); cfg.computeUnits = units
        let model = try MLModel(contentsOf: compiled, configuration: cfg)
        let n = min(rows, data.testCount)
        let cpu = cpuScores(w, hidden: H, x: Array(data.testX[0..<(n * featureDim)]), rows: n)
        var okML = 0, okCPU = 0, same = 0; var maxDiff: Float = 0
        for i in 0..<n {
            let arr = try MLMultiArray(shape: [NSNumber(value: featureDim)], dataType: .float32)
            for k in 0..<featureDim { arr[k] = NSNumber(value: data.testX[i * featureDim + k]) }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: arr)]))
            guard let s = out.featureValue(for: outputName)?.multiArrayValue else { continue }
            var best = 0, bestV = -Float.infinity, cbest = 0, cbestV = -Float.infinity
            for c in 0..<numClasses {
                let v = s[c].floatValue, cv = cpu[i * numClasses + c]
                maxDiff = max(maxDiff, abs(v - cv))
                if v > bestV { bestV = v; best = c }; if cv > cbestV { cbestV = cv; cbest = c }
            }
            if best == Int(data.testY[i]) { okML += 1 }; if cbest == Int(data.testY[i]) { okCPU += 1 }; if best == cbest { same += 1 }
        }
        let u: String = { switch units { case .cpuOnly: return "CPU"; case .cpuAndGPU: return "CPU+GPU"; default: return "all" } }()
        return Verification(rows: n, coreMLAccuracy: Double(okML) / Double(n), cpuAccuracy: Double(okCPU) / Double(n), maxAbsDiff: maxDiff, sameTop1: same, computeUnits: u)
    }
}
