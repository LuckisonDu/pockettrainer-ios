// GitHubImport.swift —— 从 GitHub / Hugging Face 导入开源项目：只下载「文本源码」，只显示和编辑，绝不执行（Apple 规则 2.5.2）
// 流程：解析网址 → GitHub / Hugging Face 公共 API 取文件列表 → 过滤（文本白名单 / 大小 / 数量）→ 从 raw.githubusercontent.com 下载 → 记录每个文件的 SHA-256
import Foundation
import CryptoKit

enum GitHubImport {
    // ---- 安全规则（都在这里，一眼能看全）
    static let hosts: Set<String> = ["github.com", "api.github.com", "raw.githubusercontent.com", "huggingface.co", "cas-bridge.xethub.hf.co"]     // 只许这几个网站
    /// huggingface.co 的大文件会跳到它自己的 CDN（*.cdn.hf.co、*.xethub.hf.co、cdn-lfs*.huggingface.co），也允许
    static func hostAllowed(_ h: String) -> Bool { hosts.contains(h) || h.hasSuffix(".hf.co") || h.hasSuffix(".huggingface.co") }
    /// 模型权重：Hugging Face 项目里只「列出」，不默认下载；用户逐个点才下载（≤ 50 MB），只存放和显示，不执行
    static let weightExt: Set<String> = ["safetensors", "bin", "gguf", "mlpackage", "onnx", "pt", "pth", "h5", "ckpt", "npz", "msgpack", "pb", "tflite", "mlmodel", "ot", "mlmodelc"]
    static let maxWeight = 50 * 1024 * 1024, maxCoreML = 100 * 1024 * 1024, maxTable = 5 * 1024 * 1024
    static let textExt: Set<String> = ["py", "md", "txt", "json", "yaml", "yml", "toml", "cfg", "ini", "csv", "ipynb", "swift", "kt", "js", "ts",
                                       "jsx", "tsx", "jsonl", "java", "c", "h", "cpp", "hpp", "cc", "rs", "go", "rb", "sh", "html", "css", "rst", "tex", "r", "m", "lua"]
    static let textNames: Set<String> = ["license", "licence", "copying", "readme", "makefile", "dockerfile", "notice", "authors", "citation", ".gitignore"]
    static let maxFile = 512 * 1024, maxCount = 200, maxTotal = 5 * 1024 * 1024
    static let maxCSV = 64 * 1024            // csv 只收小的

    struct Failure: LocalizedError { let errorDescription: String?; var notFound = false }

    enum Source: String { case github, hf, hfDataset }
    struct Ref {
        var source = Source.github
        var owner: String, repo: String, branch: String?, subdir: String, file: String?
        /// Hugging Face 的 id：org/name 或单个名字（如 gpt2）
        var hfID: String { owner.isEmpty ? repo : owner + "/" + repo }
    }
    struct Entry: Codable { var path: String, sha256: String, url: String, bytes: Int }
    struct Skipped: Codable { var path: String, reason: String }
    struct Weight: Codable, Identifiable { var path: String, size: Int, url: String; var id: String { path } }
    struct Summary {
        var project = "", source = "", license: String?, licenseText: String?
        var files: [Entry] = [], skipped: [Skipped] = [], weights: [Weight] = [], bytes = 0, seconds = 0.0
        var tooBig: [(dir: String, count: Int, bytes: Int)] = []      // 超限时给用户的子目录建议
    }

    // MARK: 解析网址

    /// 接受 GitHub：https://github.com/<o>/<r>、/tree/<分支>[/<子目录>]、/blob/<分支>/<文件>
    /// 和 Hugging Face：https://huggingface.co/<org>/<name>、https://huggingface.co/datasets/<org>/<name>（可带 /tree/main/<子目录>）
    static func parse(_ text: String) throws -> Ref {
        let bad = Failure(errorDescription: tr("That is not a GitHub address. Use https://github.com/<owner>/<repo>"))
        guard let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme == "https",
              ["github.com", "www.github.com", "huggingface.co"].contains(u.host ?? "") else { throw bad }
        var p = u.pathComponents.filter { $0 != "/" }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        if u.host == "huggingface.co" {
            var src = Source.hf
            if p.first == "datasets" { src = .hfDataset; p.removeFirst() }
            guard !p.isEmpty, !["spaces", "docs", "api", "blog", "models"].contains(p[0]) else { throw bad }
            // org/name 或单个名字；后面可以跟 tree|blob|resolve / 分支 / 路径
            let named = p.count >= 2 && !["tree", "blob", "resolve"].contains(p[1])
            var r = Ref(source: src, owner: named ? p[0] : "", repo: named ? p[1] : p[0], branch: nil, subdir: "", file: nil)
            let rest = Array(p.dropFirst(named ? 2 : 1))
            if rest.count >= 2, rest[0] == "tree" { r.branch = rest[1]; r.subdir = rest.dropFirst(2).joined(separator: "/") }
            if rest.count >= 3, rest[0] == "blob" || rest[0] == "resolve" { r.branch = rest[1]; r.file = rest.dropFirst(2).joined(separator: "/") }
            guard [r.owner, r.repo].allSatisfy({ $0.unicodeScalars.allSatisfy(ok.contains) }), !r.repo.isEmpty else { throw bad }
            return r
        }
        guard p.count >= 2 else { throw bad }
        var r = Ref(owner: p[0], repo: p[1].replacingOccurrences(of: ".git", with: ""), branch: nil, subdir: "", file: nil)
        if p.count >= 4, p[2] == "tree" { r.branch = p[3]; r.subdir = p.dropFirst(4).joined(separator: "/") }
        if p.count >= 5, p[2] == "blob" { r.branch = p[3]; r.file = p.dropFirst(4).joined(separator: "/") }
        guard [r.owner, r.repo].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(ok.contains) }) else { throw bad }
        return r
    }

    // MARK: 联网（只许白名单网站，重定向也检查）

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest req: URLRequest) async -> URLRequest? {
            (req.url?.scheme == "https" && GitHubImport.hostAllowed(req.url?.host ?? "")) ? req : nil
        }
    }
    static let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

    /// 友好的限流/错误提示（GitHub 和 Hugging Face 都用）
    static func check(_ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { throw Failure(errorDescription: tr("Unexpected answer from GitHub.")) }
        if h.statusCode == 403 || h.statusCode == 429 {      // 未登录的 API 每小时约 60 次
            var when = ""
            if let reset = (h.value(forHTTPHeaderField: "x-ratelimit-reset") ?? h.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init), reset > 1_000_000 {
                let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; when = f.string(from: Date(timeIntervalSince1970: reset))
            }
            throw Failure(errorDescription: when.isEmpty ? tr("The server is limiting requests right now. Please try again later.")
                                                        : tr("GitHub allows only about 60 requests per hour without login. Please try again after %@.", when))
        }
        guard h.statusCode == 200 else { throw Failure(errorDescription: h.statusCode == 404 ? tr("Not found on GitHub. Is the repository public?") : tr("GitHub answered with error %ld.", h.statusCode), notFound: h.statusCode == 404) }
    }

    static func get(_ url: URL, api: Bool = false) async throws -> Data {
        guard url.scheme == "https", hostAllowed(url.host ?? "") else { throw Failure(errorDescription: tr("Blocked: only github.com addresses are allowed.")) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("PocketTrainer", forHTTPHeaderField: "User-Agent")
        if api { req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw Failure(errorDescription: tr("Could not reach GitHub. Check your internet connection. (PocketTrainer only goes online when you import.)")) }
        try check(resp)
        return data
    }

    static func json(_ url: String) async throws -> Any {
        guard let u = URL(string: url) else { throw Failure(errorDescription: tr("Unexpected answer from GitHub.")) }
        return try JSONSerialization.jsonObject(with: try await get(u, api: true))
    }
    private static func jsonDict(_ url: String) async throws -> [String: Any] {
        guard let j = try await json(url) as? [String: Any] else { throw Failure(errorDescription: tr("Unexpected answer from GitHub.")) }
        return j
    }

    // MARK: 过滤

    /// 这个文件要不要下载？不要就返回原因
    static func skipReason(_ path: String, size: Int) -> String? {
        let comps = path.split(separator: "/").map(String.init)
        let name = comps.last ?? path, ext = (name as NSString).pathExtension.lowercased()
        if comps.contains(where: { $0.hasPrefix(".") && $0 != ".gitignore" }) { return "hidden" }
        if path.contains("..") { return "bad path" }
        let ok = ext.isEmpty ? textNames.contains(name.lowercased()) : (textExt.contains(ext) || textNames.contains(name.lowercased()))
        if !ok { return "file type not allowed" }
        if size > maxFile { return "larger than 512 KB" }
        if ext == "csv" && size > maxCSV { return "csv larger than 64 KB" }
        return nil
    }

    // MARK: 第一步：列文件、过滤（不下载内容）

    struct Plan {
        var ref: Ref, url: String, branch: String, prefix: String
        var license: String?
        var want: [(path: String, size: Int)] = []
        var weights: [Weight] = []
        var skipped: [Skipped] = []
        var licensePath: String?
        var name: String
        var rawBase: String            // 下载单个文件的网址前缀
        func rawURL(_ path: String) -> URL? {
            let enc = path.split(separator: "/").map { String($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "") }.joined(separator: "/")
            return URL(string: rawBase + enc)
        }
    }

    static func plan(url: String, progress: @escaping (String) -> Void) async throws -> Plan {
        let ref = try parse(url)
        var plan: Plan
        var items: [(path: String, size: Int)] = []
        if ref.source == .github {
            progress(tr("Asking GitHub about %@/%@…", ref.owner, ref.repo))
            let info = try await jsonDict("https://api.github.com/repos/\(ref.owner)/\(ref.repo)")
            let branch = ref.branch ?? (info["default_branch"] as? String ?? "main")
            let spdx = ((info["license"] as? [String: Any])?["spdx_id"] as? String).flatMap { $0 == "NOASSERTION" ? nil : $0 }
            let tree = try await jsonDict("https://api.github.com/repos/\(ref.owner)/\(ref.repo)/git/trees/\(branch)?recursive=1")
            if tree["truncated"] as? Bool == true { throw Failure(errorDescription: tr("This repository is too large to list. Use a link to a sub-folder, like github.com/<owner>/<repo>/tree/<branch>/<folder>.")) }
            items = (tree["tree"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "blob" }.compactMap { it in (it["path"] as? String).map { ($0, it["size"] as? Int ?? 0) } }
            plan = Plan(ref: ref, url: url, branch: branch, prefix: ref.subdir.isEmpty ? "" : ref.subdir + "/", license: spdx, name: ref.repo,
                        rawBase: "https://raw.githubusercontent.com/\(ref.owner)/\(ref.repo)/\(branch)/")
        } else {
            let kind = ref.source == .hfDataset ? "datasets" : "models"
            progress(tr("Asking Hugging Face about %@…", ref.hfID))
            let info = try await jsonDict("https://huggingface.co/api/\(kind)/\(ref.hfID)?blobs=true")
            let tags = info["tags"] as? [String] ?? []
            let lic = ((info["cardData"] as? [String: Any])?["license"] as? String) ?? tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) }
            items = (info["siblings"] as? [[String: Any]] ?? []).compactMap { it in (it["rfilename"] as? String).map { ($0, it["size"] as? Int ?? 0) } }
            let base = "https://huggingface.co/" + (ref.source == .hfDataset ? "datasets/" : "") + ref.hfID + "/resolve/main/"
            plan = Plan(ref: ref, url: url, branch: "main", prefix: ref.subdir.isEmpty ? "" : ref.subdir + "/", license: lic, name: ref.repo, rawBase: base)
        }
        guard !items.isEmpty else { throw Failure(errorDescription: tr("No files found in that repository or branch.")) }

        // 选出这次要看的文件：整个仓库 / 某个子目录 / 单个文件
        for (p, size) in items {
            if let f = ref.file { if p != f { continue } } else if !plan.prefix.isEmpty && !p.hasPrefix(plan.prefix) { continue }
            if ref.source != .github {
                let ext = (p as NSString).pathExtension.lowercased()
                let inPackage = p.split(separator: "/").contains { $0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc") }     // Core ML 包是一个文件夹
                let bigTable = (ext == "csv" || ext == "jsonl") && size > maxCSV && size <= maxTable                              // 大一点的表格：用户点了才下载
                if inPackage || weightExt.contains(ext) || ext == "zip" || bigTable {      // 模型/数据：只列出，不默认下载
                    plan.weights.append(Weight(path: p, size: size, url: plan.rawURL(p)?.absoluteString ?? "")); continue }
            }
            if let why = skipReason(p, size: size) { plan.skipped.append(.init(path: p, reason: why)) } else { plan.want.append((p, size)) }
        }
        // 找 LICENSE（在仓库根目录），子目录/单文件导入时也一并取
        plan.licensePath = items.map(\.path).first { !$0.contains("/") && ["license", "license.md", "license.txt", "licence", "copying"].contains($0.lowercased()) }
        if let lp = plan.licensePath, !plan.want.contains(where: { $0.path == lp }) { plan.want.append((lp, 0)) }
        plan.want.sort { ($0.path.contains("/") ? 1 : 0, $0.path) < ($1.path.contains("/") ? 1 : 0, $1.path) }

        let total = plan.want.reduce(0) { $0 + $1.size }
        if plan.want.count > maxCount || total > maxTotal {      // 超限：不下载，给子目录建议
            var dirs: [String: (Int, Int)] = [:]
            for w in plan.want { let d = w.path.contains("/") ? String(w.path.split(separator: "/")[0]) : "."; dirs[d, default: (0, 0)].0 += 1; dirs[d, default: (0, 0)].1 += w.size }
            var sum = Summary(); sum.source = url; sum.license = plan.license
            sum.tooBig = dirs.filter { $0.key != "." }.map { (dir: $0.key, count: $0.value.0, bytes: $0.value.1) }.sorted { $0.count > $1.count }
            throw TooBig(summary: sum, errorDescription: tr("This is too big to import (%ld files, %.1f MB; limits: 200 files, 5 MB). Pick a sub-folder.", plan.want.count, Double(total) / 1_048_576))
        }
        if ref.file != nil { plan.name = ref.repo }
        else if !ref.subdir.isEmpty { plan.name = "\(ref.repo)-\((ref.subdir as NSString).lastPathComponent)" }
        return plan
    }

    // MARK: 第二步：下载一个文件（文本检查）；返回 nil 表示跳过（原因写进 skipped）

    static func fetch(_ plan: Plan, _ path: String, skipped: inout [Skipped]) async throws -> Data? {
        guard let raw = plan.rawURL(path) else { return nil }
        let data: Data
        do { data = try await get(raw) } catch let f as Failure where f.notFound { skipped.append(.init(path: path, reason: "download failed")); return nil }
        if data.count > maxFile { skipped.append(.init(path: path, reason: "larger than 512 KB")); return nil }
        if data.contains(0) || String(data: data, encoding: .utf8) == nil { skipped.append(.init(path: path, reason: "not plain text")); return nil }
        return data
    }

    // MARK: 第三步：把文件写进新项目，留来源记录

    static func install(_ plan: Plan, cache: [String: Data] = [:], store: ProjectStore, progress: @escaping (String) -> Void) async throws -> Summary {
        let t0 = Date()
        var sum = Summary(); sum.source = plan.url; sum.license = plan.license; sum.skipped = plan.skipped; sum.weights = plan.weights
        var name = plan.name.replacingOccurrences(of: "/", with: "-"), k = 2; let base = name
        while FileManager.default.fileExists(atPath: ProjectStore.dir(name).path) { name = "\(base) \(k)"; k += 1 }
        let dir = ProjectStore.dir(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for sub in ["checkpoints", "notes", "results", "models"] { try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        var done = 0
        for w in plan.want {
            done += 1
            progress(tr("Downloading %ld of %ld: %@", done, plan.want.count, (w.path as NSString).lastPathComponent))
            let data: Data
            if let c = cache[w.path] { data = c } else if let d = try await fetch(plan, w.path, skipped: &sum.skipped) { data = d } else { continue }
            // 本地路径：去掉子目录前缀；LICENSE 放根目录
            var rel = (plan.prefix.isEmpty || !w.path.hasPrefix(plan.prefix)) ? w.path : String(w.path.dropFirst(plan.prefix.count))
            if plan.ref.file != nil { rel = (w.path as NSString).lastPathComponent }
            let dest = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            sum.files.append(.init(path: rel, sha256: sha, url: plan.rawURL(w.path)?.absoluteString ?? "", bytes: data.count))
            sum.bytes += data.count
            if w.path == plan.licensePath { sum.licenseText = String(data: data, encoding: .utf8) }
        }
        sum.project = name; sum.seconds = -t0.timeIntervalSinceNow
        let rec: [String: Any] = ["source": plan.url, "branch": plan.branch, "license": plan.license ?? "unknown", "kind": plan.ref.source.rawValue,
                                  "importedAt": ISO8601DateFormatter().string(from: Date()),
                                  "files": sum.files.map { ["path": $0.path, "sha256": $0.sha256, "url": $0.url, "bytes": $0.bytes] },
                                  "skipped": sum.skipped.map { ["path": $0.path, "reason": $0.reason] },
                                  "weights": sum.weights.map { ["path": $0.path, "size": $0.size, "url": $0.url] }]
        try JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent(".pt_import.json"))
        await MainActor.run { store.reload() }
        return sum
    }

    /// 一步到位：列出 + 下载 + 写入（「Import from GitHub」界面和自动测试用）
    static func run(url: String, store: ProjectStore, progress: @escaping (String) -> Void) async throws -> Summary {
        let p = try await plan(url: url, progress: progress)
        return try await install(p, store: store, progress: progress)
    }

    struct TooBig: LocalizedError { let summary: Summary; let errorDescription: String? }

    // MARK: 模型权重：用户点了才下载（≤ 50 MB），只存放、只读 safetensors 头部，绝不执行

    struct TensorInfo { let name: String, dtype: String, shape: [Int] }

    static func downloadWeight(_ w: Weight, project: String, limit: Int = maxWeight, into: String? = nil) async throws -> URL {
        guard w.size <= limit, let u = URL(string: w.url) else { throw Failure(errorDescription: tr("This file is larger than 50 MB and will not be downloaded.")) }
        guard u.scheme == "https", hostAllowed(u.host ?? "") else { throw Failure(errorDescription: tr("Blocked: only github.com addresses are allowed.")) }
        var req = URLRequest(url: u, timeoutInterval: 120); req.setValue("PocketTrainer", forHTTPHeaderField: "User-Agent")
        let (tmp, resp): (URL, URLResponse)
        do { (tmp, resp) = try await session.download(for: req) } catch { throw Failure(errorDescription: tr("Could not reach GitHub. Check your internet connection. (PocketTrainer only goes online when you import.)")) }
        try check(resp)
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        guard size <= limit else { try? FileManager.default.removeItem(at: tmp); throw Failure(errorDescription: tr("This file is larger than 50 MB and will not be downloaded.")) }
        let dest = ProjectStore.dir(project).appendingPathComponent("models/" + (into ?? w.path.replacingOccurrences(of: "/", with: "_")))
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// safetensors 文件开头：8 字节长度 N + N 字节 JSON（张量名、类型、形状）。只读这一小段。
    static func safetensorsHeader(_ url: URL) -> [TensorInfo]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let lenData = try? h.read(upToCount: 8), lenData.count == 8 else { return nil }
        let n = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard n > 0, n < 10_000_000, let d = try? h.read(upToCount: n), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return j.compactMap { k, v in
            guard k != "__metadata__", let t = v as? [String: Any] else { return nil }
            return TensorInfo(name: k, dtype: t["dtype"] as? String ?? "?", shape: t["shape"] as? [Int] ?? [])
        }.sorted { $0.name < $1.name }
    }
}
