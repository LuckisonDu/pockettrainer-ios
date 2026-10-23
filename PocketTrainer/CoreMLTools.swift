// CoreMLTools.swift —— Hugging Face 上的 Core ML 模型：下载 → 设备端编译 → 运行 → GPU/CPU 双重核对
// Core ML 模型是「数据」（权重 + 计算图），由系统的 Core ML 引擎执行；Apple 允许运行时下载并用 MLModel.compileModel 在设备上编译。
// 这里不运行任何下载来的代码。
import Foundation
import CoreML
import Compression
import UIKit

struct CoreMLCandidate: Identifiable {
    enum Kind { case mlmodel, package, zip }
    var id: String { name }
    let name: String, kind: Kind, size: Int
    let files: [GitHubImport.Weight]        // package 是一个文件夹，有很多文件
}

enum CoreMLTools {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// 项目导入记录里列出的模型文件中，找可以运行的 Core ML 模型（单个 .mlmodel、.mlpackage 文件夹、或 zip）
    static func candidates(project: String) -> [CoreMLCandidate] {
        guard let d = try? Data(contentsOf: ProjectStore.dir(project).appendingPathComponent(".pt_import.json")),
              let rec = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let ws = rec["weights"] as? [[String: Any]] else { return [] }
        let weights = ws.compactMap { w -> GitHubImport.Weight? in
            guard let p = w["path"] as? String, let u = w["url"] as? String else { return nil }
            return GitHubImport.Weight(path: p, size: w["size"] as? Int ?? 0, url: u)
        }
        var out: [CoreMLCandidate] = []
        var packages: [String: [GitHubImport.Weight]] = [:]
        for w in weights {
            let comps = w.path.split(separator: "/").map(String.init)
            if let i = comps.firstIndex(where: { $0.hasSuffix(".mlpackage") }) { packages[comps[0...i].joined(separator: "/"), default: []].append(w) }
            else if w.path.hasSuffix(".mlmodel") { out.append(CoreMLCandidate(name: (w.path as NSString).lastPathComponent, kind: .mlmodel, size: w.size, files: [w])) }
            else if w.path.hasSuffix(".zip") { out.append(CoreMLCandidate(name: (w.path as NSString).lastPathComponent, kind: .zip, size: w.size, files: [w])) }
        }
        for (prefix, fs) in packages { out.append(CoreMLCandidate(name: (prefix as NSString).lastPathComponent, kind: .package, size: fs.reduce(0) { $0 + $1.size }, files: fs)) }
        return out.sorted { $0.size < $1.size }
    }

    static func compiledURL(project: String, name: String) -> URL { ProjectStore.dir(project).appendingPathComponent("models/\(name).mlmodelc") }

    /// 下载（≤ 100 MB）→ 解压 → 在设备上编译。progress 报告 0~1 和说明；任务被取消就停
    static func prepare(_ c: CoreMLCandidate, project: String, progress: @escaping (Double, String) -> Void) async throws -> URL {
        guard c.size <= GitHubImport.maxCoreML else { throw Failure(errorDescription: tr("This model is larger than 100 MB and will not be downloaded.")) }
        let models = ProjectStore.dir(project).appendingPathComponent("models/coreml", isDirectory: true)
        var source: URL
        switch c.kind {
        case .mlmodel:
            progress(0.1, tr("Downloading %@", c.name))
            source = try await GitHubImport.downloadWeight(c.files[0], project: project, limit: GitHubImport.maxCoreML, into: "coreml/" + c.name)
        case .package:
            for (i, f) in c.files.enumerated() {
                try Task.checkCancellation()
                progress(Double(i) / Double(c.files.count) * 0.8, tr("Downloading %ld of %ld: %@", i + 1, c.files.count, (f.path as NSString).lastPathComponent))
                _ = try await GitHubImport.downloadWeight(f, project: project, limit: GitHubImport.maxCoreML, into: "coreml/" + f.path)
            }
            let comps = c.files[0].path.split(separator: "/").map(String.init)
            let i = comps.firstIndex { $0.hasSuffix(".mlpackage") }!
            source = models.appendingPathComponent(comps[0...i].joined(separator: "/"))
        case .zip:
            progress(0.1, tr("Downloading %@", c.name))
            let z = try await GitHubImport.downloadWeight(c.files[0], project: project, limit: GitHubImport.maxCoreML, into: "coreml/" + c.name)
            progress(0.6, tr("Unpacking %@", c.name))
            let dest = models.appendingPathComponent((c.name as NSString).deletingPathExtension, isDirectory: true)
            try? FileManager.default.removeItem(at: dest)
            try ZipReader.extract(z, to: dest)
            guard let found = findModel(in: dest) else { throw Failure(errorDescription: tr("No runnable Core ML model found")) }
            source = found
        }
        try Task.checkCancellation()
        progress(0.9, tr("Compiling on this phone…"))
        let compiled = try await MLModel.compileModel(at: source)
        let dest = compiledURL(project: project, name: (c.name as NSString).deletingPathExtension)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: compiled, to: dest)
        progress(1, tr("Model ready"))
        return dest
    }

    private static func findModel(in dir: URL) -> URL? {
        let all = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        return all.first { $0.pathExtension == "mlpackage" } ?? all.first { $0.pathExtension == "mlmodel" }
    }

    /// 模型的输入/输出说明
    static func describe(_ url: URL) -> [String] {
        guard let m = try? MLModel(contentsOf: url) else { return [] }
        func line(_ n: String, _ d: MLFeatureDescription) -> String {
            switch d.type {
            case .image: let c = d.imageConstraint; return "\(n): image \(c?.pixelsWide ?? 0)×\(c?.pixelsHigh ?? 0)"
            case .multiArray: return "\(n): array \(d.multiArrayConstraint?.shape.map(\.intValue) ?? [])"
            case .dictionary: return "\(n): dictionary (label → probability)"
            case .string: return "\(n): text"
            default: return "\(n): \(d.type.rawValue)"
            }
        }
        let d = m.modelDescription
        return d.inputDescriptionsByName.sorted { $0.key < $1.key }.map { "in  " + line($0.key, $0.value) } + d.outputDescriptionsByName.sorted { $0.key < $1.key }.map { "out " + line($0.key, $0.value) }
    }

    struct Prediction { var top: [(label: String, p: Double)]; var vector: [Double]; var seconds: Double }

    /// 在指定的计算单元上跑一次（只 CPU / CPU+GPU）
    static func predict(_ url: URL, image: CGImage, units: MLComputeUnits) throws -> Prediction {
        let cfg = MLModelConfiguration(); cfg.computeUnits = units
        let m = try MLModel(contentsOf: url, configuration: cfg)
        guard let (name, d) = m.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }), let ic = d.imageConstraint else {
            throw Failure(errorDescription: tr("This model needs an input that is not a photo. Only image models can be run here.")) }
        let fv = try MLFeatureValue(cgImage: image, constraint: ic, options: nil)
        let t0 = Date()
        let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: fv]))
        let secs = -t0.timeIntervalSinceNow
        // 优先取「标签 → 概率」字典；其次取一个向量
        for n in out.featureNames.sorted() {
            if let dict = out.featureValue(for: n)?.dictionaryValue, !dict.isEmpty {
                let items = dict.map { (String(describing: $0.key), $0.value.doubleValue) }.sorted { $0.0 < $1.0 }
                return Prediction(top: items.sorted { $0.1 > $1.1 }.prefix(5).map { ($0.0, $0.1) }, vector: items.map(\.1), seconds: secs)
            }
        }
        for n in out.featureNames.sorted() {
            if let arr = out.featureValue(for: n)?.multiArrayValue, arr.count <= 100_000 {
                let v = (0..<arr.count).map { arr[$0].doubleValue }
                let top = v.enumerated().sorted { $0.element > $1.element }.prefix(5).map { ("#\($0.offset)", $0.element) }
                return Prediction(top: top, vector: v, seconds: secs)
            }
        }
        throw Failure(errorDescription: tr("No classification or vector output found."))
    }

    /// GPU 结果和 CPU 结果对比：余弦相似度 ≥ 0.999 且最大差 ≤ 0.02 才算一致（fp16 的 GPU 和 fp32 的 CPU 本来就会差一点点）
    static func compare(_ a: [Double], _ b: [Double]) -> (cos: Double, maxDiff: Double, ok: Bool) {
        guard a.count == b.count, !a.isEmpty else { return (0, .infinity, false) }
        var dot = 0.0, na = 0.0, nb = 0.0, md = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; md = max(md, abs(a[i] - b[i])) }
        let cos = dot / max((na * nb).squareRoot(), 1e-30)
        return (cos, md, cos >= 0.999 && md <= 0.02)
    }

    /// 内置示例图：程序画的（不含任何人像）
    static func sampleImage() -> CGImage {
        UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            UIColor.white.setFill(); c.cgContext.fillEllipse(in: CGRect(x: 60, y: 60, width: 136, height: 136))
            UIColor.systemOrange.setFill(); c.fill(CGRect(x: 0, y: 190, width: 256, height: 66))
        }.cgImage!
    }
}

/// 最小的 zip 解压器（只支持 stored 和 deflate，够用就行）；路径检查防止写到目录外面
enum ZipReader {
    static func extract(_ zip: URL, to dest: URL) throws {
        let d = try Data(contentsOf: zip, options: .mappedIfSafe)
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard let eocd = (0...min(d.count - 22, 65_557)).lazy.map({ d.count - 22 - $0 }).first(where: { $0 >= 0 && u32($0) == 0x06054b50 }) else {
            throw CoreMLTools.Failure(errorDescription: tr("This is not a valid zip file.")) }
        var off = u32(eocd + 16)
        let count = u16(eocd + 10)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for _ in 0..<count {
            guard u32(off) == 0x02014b50 else { break }
            let method = u16(off + 10), csize = u32(off + 20), usize = u32(off + 24)
            let nlen = u16(off + 28), xlen = u16(off + 30), clen = u16(off + 32), lho = u32(off + 42)
            let name = String(decoding: d[(off + 46)..<(off + 46 + nlen)], as: UTF8.self)
            off += 46 + nlen + xlen + clen
            if name.hasSuffix("/") || name.contains("..") || name.hasPrefix("/") || name.hasPrefix("__MACOSX") { continue }
            let dataStart = lho + 30 + u16(lho + 26) + u16(lho + 28)
            let comp = d[dataStart..<(dataStart + csize)]
            var out: Data
            if method == 0 { out = Data(comp) }
            else if method == 8 {
                var buf = [UInt8](repeating: 0, count: usize)
                let n = comp.withUnsafeBytes { src in buf.withUnsafeMutableBytes { dst in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, usize, src.bindMemory(to: UInt8.self).baseAddress!, csize, nil, COMPRESSION_ZLIB) } }
                guard n == usize else { throw CoreMLTools.Failure(errorDescription: tr("This is not a valid zip file.")) }
                out = Data(buf)
            } else { throw CoreMLTools.Failure(errorDescription: tr("This is not a valid zip file.")) }
            let target = dest.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: target)
        }
    }
}
