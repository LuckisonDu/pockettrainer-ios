// DepScan.swift —— 「Analyze / Resolve」的真逻辑：读依赖文件和 import 语句，列出项目需要的包，再对照本 App 能提供的东西
// 诚实原则：PocketTrainer 不运行 Python，也不能 pip install。所以除了 App 内置的组件，其余包都是 "Not available on iOS"。
import Foundation

struct Requirement: Identifiable {
    var id: String { name }
    let name: String            // 规范化的包名（小写）
    let spec: String            // 版本要求，没有就是 ""
    let source: String          // 从哪里读到的：requirements.txt / pyproject.toml / import …
}

/// 一个包的判定结果
struct PackageVerdict: Identifiable {
    var id: String { name }
    let name: String, required: String, have: String
    let status: String          // Built-in / Not available on iOS / Conflict
    let reason: String          // 给用户看的原因（英文键，显示时用 tr）
}

enum DepScan {
    /// 需要原生代码的大型库（iOS App 不能下载这类代码）
    static let native: Set<String> = ["torch", "torchvision", "torchaudio", "tensorflow", "keras", "jax", "jaxlib", "numpy", "scipy", "pandas", "scikit-learn",
        "opencv-python", "opencv-python-headless", "pillow", "matplotlib", "transformers", "tokenizers", "safetensors", "datasets", "sentence-transformers",
        "onnxruntime", "xgboost", "lightgbm", "accelerate", "diffusers", "numba", "cython", "h5py", "pyarrow", "grpcio", "cryptography"]
    /// import 名 → 包名
    static let alias: [String: String] = ["cv2": "opencv-python", "PIL": "pillow", "sklearn": "scikit-learn", "yaml": "pyyaml", "bs4": "beautifulsoup4",
        "skimage": "scikit-image", "tf": "tensorflow", "attr": "attrs", "dateutil": "python-dateutil", "google": "protobuf"]
    static let stdlib: Set<String> = ["os", "sys", "re", "json", "math", "random", "time", "typing", "collections", "itertools", "functools", "pathlib", "argparse",
        "logging", "dataclasses", "subprocess", "datetime", "copy", "io", "abc", "enum", "string", "glob", "shutil", "tempfile", "threading", "multiprocessing",
        "unittest", "pickle", "csv", "struct", "hashlib", "urllib", "http", "socket", "contextlib", "heapq", "bisect", "operator", "warnings", "traceback",
        "inspect", "gzip", "zipfile", "tarfile", "base64", "uuid", "platform", "textwrap", "decimal", "fractions", "statistics", "secrets", "queue", "signal",
        "ctypes", "__future__", "importlib", "pprint", "types", "weakref", "array", "numbers", "sqlite3", "xml", "html", "email", "asyncio", "concurrent", "ast",
        "builtins", "codecs", "locale", "gc", "atexit", "shlex", "getpass", "configparser", "zlib", "bz2", "lzma", "select", "ssl", "unicodedata", "tkinter", "turtle", "cmath", "timeit", "cProfile", "pdb", "doctest"]

    static func normalize(_ n: String) -> String { n.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-") }

    /// files: 项目里的文本文件 路径 → 内容
    static func scan(files: [String: String]) -> [Requirement] {
        var out: [String: Requirement] = [:]
        func add(_ raw: String, _ spec: String, _ src: String) {
            let n = normalize(raw)
            guard !n.isEmpty, out[n] == nil || out[n]!.spec.isEmpty && !spec.isEmpty else { return }
            out[n] = Requirement(name: n, spec: spec, source: src)
        }
        let pkgRe = try! NSRegularExpression(pattern: "^\\s*([A-Za-z0-9][A-Za-z0-9._-]*)\\s*(?:\\[[^\\]]*\\])?\\s*((?:[<>=!~]=?[^;#,\\s]*(?:\\s*,\\s*[<>=!~]=?[^;#,\\s]*)*)?)")
        func fromLine(_ line: String, _ src: String) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("-") || l.hasPrefix("git+") || l.contains("://") { return }
            if let m = pkgRe.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let n = Range(m.range(at: 1), in: l), let v = Range(m.range(at: 2), in: l) {
                add(String(l[n]), String(l[v]), src)
            }
        }
        let quoted = try! NSRegularExpression(pattern: "[\"']([A-Za-z0-9][A-Za-z0-9._\\[\\]-]*\\s*[<>=!~]*[^\"']*)[\"']")
        for (path, text) in files {
            let name = (path as NSString).lastPathComponent.lowercased()
            if name.hasPrefix("requirements") && name.hasSuffix(".txt") {
                for l in text.components(separatedBy: "\n") { fromLine(l, name) }
            } else if name == "environment.yml" || name == "environment.yaml" {
                for l in text.components(separatedBy: "\n") {
                    let t = l.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("- "), !t.hasPrefix("- pip"), !t.hasPrefix("- python") else { continue }
                    let item = String(t.dropFirst(2))
                    fromLine(item.contains("==") ? item : item.replacingOccurrences(of: "=", with: "=="), name)       // conda 的 numpy=1.2 → numpy==1.2
                }
            } else if name == "pyproject.toml" || name == "setup.py" || name == "setup.cfg" {
                // 只看 dependencies / install_requires 那一段里带引号的字符串
                for key in ["dependencies", "install_requires", "requires"] {
                    var from = text.startIndex
                    while let r = text.range(of: key, range: from..<text.endIndex) {
                        from = r.upperBound
                        guard let open = text[from...].firstIndex(of: "["), text[from..<open].allSatisfy({ " =:\n\t".contains($0) }), let close = text[open...].firstIndex(of: "]") else { continue }
                        let block = String(text[open..<close])
                        for m in quoted.matches(in: block, range: NSRange(block.startIndex..., in: block)) { if let rr = Range(m.range(at: 1), in: block) { fromLine(String(block[rr]), name) } }
                    }
                }
                if name == "setup.cfg" { for l in text.components(separatedBy: "\n") where l.hasPrefix("    ") { fromLine(l, name) } }
            }
        }
        // import 语句（.py）：顶层模块名，排除标准库和项目自己的文件
        let local = Set(files.keys.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } + files.keys.flatMap { $0.split(separator: "/").map(String.init) })
        let imp = try! NSRegularExpression(pattern: "^\\s*(?:import|from)\\s+([A-Za-z_][A-Za-z0-9_]*)", options: [.anchorsMatchLines])
        for (path, text) in files where path.hasSuffix(".py") {
            for m in imp.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let mod = String(text[r])
                if stdlib.contains(mod) || local.contains(mod) || mod.hasPrefix("_") { continue }
                add(alias[mod] ?? mod, "", "import")
            }
        }
        return out.values.sorted { $0.name < $1.name }
    }

    /// 对照本 App 内置的组件，给每个包一个判定
    static func resolve(_ reqs: [Requirement]) -> [PackageVerdict] {
        reqs.map { r in
            if let b = Builtin.packages.first(where: { $0.name == r.name }) {
                let need = r.spec.trimmingCharacters(in: CharacterSet(charactersIn: "<>=!~ "))
                let ok = need.isEmpty || need.split(separator: ".").first == b.version.split(separator: ".").first
                return PackageVerdict(name: r.name, required: r.spec, have: b.version, status: ok ? "Built-in" : "Conflict", reason: ok ? b.role : "Version conflict")
            }
            let reason = native.contains(r.name) ? "needs native code that iOS apps cannot download" : "PocketTrainer does not run Python code"
            return PackageVerdict(name: r.name, required: r.spec, have: "-", status: "Not available on iOS", reason: reason)
        }
    }

    /// 项目总判定：Ready to run / Read & edit only / Missing: …
    static func report(recipe: Bool, verdicts: [PackageVerdict]) -> String {
        if recipe { return "Ready to run" }
        let missing = verdicts.filter { $0.status != "Built-in" }.map(\.name)
        return missing.isEmpty ? "Read & edit only" : "Missing: " + missing.prefix(8).joined(separator: ", ")
    }
}
