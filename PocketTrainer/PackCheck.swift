// PackCheck.swift —— 「项目包」(recipe pack) 的真实校验 + 从网址下载
// 项目包 = manifest.json（清单）+ 文本配置 + 说明。里面没有、也永远不会下载「可执行代码」（Apple 规则 2.5.2）：
// .py 文件只是给学生读的文字，App 自带的训练器只读其中几行设置。
import Foundation
import CryptoKit
import UIKit

/// App 内置的「软件包」及版本：项目要求的主版本号必须和这里一致
enum Builtin {
    static let packages: [(name: String, version: String, role: String)] = [
        ("trainer-core", "1.0", "the 2-layer trainer (GPU + CPU check)"),
        ("lesson-utils", "1.0", "notes, coach and takeaways"),
        ("data-reader", "1.0", "reads data format 1 (float16 features)"),
    ]
    static let supportedFormats = [1]
    static let allowedExtensions: Set<String> = GitHubImport.textExt.union(["ckpt"])
    static func version(_ name: String) -> String? { packages.first { $0.name == name }?.version }

    /// App 里打包的数据集清单 {name, files:{文件名: sha256}}
    static var dataset: (name: String, files: [String: String]) {
        guard let u = Bundle.main.url(forResource: "dataset", withExtension: "json"),
              let j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: u))) as? [String: Any] else { return ("", [:]) }
        return (j["name"] as? String ?? "", j["files"] as? [String: String] ?? [:])
    }
}

struct PackageRow: Identifiable { var id: String { name }; let name: String; let required: String; let have: String; var status: String; var reason: String = "" }

enum PackCheck {
    /// 内置项目的 manifest.json 文本
    static func builtinManifest(title: String, kind: String) -> String {
        let ds = Builtin.dataset
        let data = ds.files.sorted { $0.key < $1.key }.map { "    {\"name\": \"\($0.key)\", \"sha256\": \"\($0.value)\"}" }.joined(separator: ",\n")
        return """
        {
          "format": 1,
          "name": "\(title)",
          "kind": "\(kind)",
          "dataset": "\(ds.name)",
          "requires": {"trainer-core": "1", "lesson-utils": "1", "data-reader": "1"},
          "files": ["code/model.py", "code/train.py", "code/config.json"],
          "data": [
        \(data)
          ]
        }

        """
    }

    static func sha256(ofBundleFile name: String) -> String? {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count == 2, let u = Bundle.main.url(forResource: parts[0], withExtension: parts[1]), let d = try? Data(contentsOf: u) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}

/// 检查器：Analyze → Resolve → Install → Test 四步，每一步都做真事，结果写进 Live log
final class EnvChecker: ObservableObject {
    static let shared = EnvChecker()      // 全 App 共用一个：Environment 页、搜索页的「Download & set up」都用它
    @Published var phase = 0                 // 已完成几步 (0...4)
    @Published var progress = 0.0            // 当前步骤里的进度 0~1
    @Published var statusText = ""
    @Published var packages: [PackageRow] = []
    @Published var conflict: String?         // 有冲突时的说明；没有就是 nil
    @Published var log: [String] = []
    @Published var passed: Bool?
    @Published var manifestText = ""
    @Published var busy = false

    private func say(_ t: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        DispatchQueue.main.async { self.log.append("\(f.string(from: Date()))  \(t)") }
    }
    private func set(phase: Int, progress: Double, text: String) {
        DispatchQueue.main.async { self.phase = phase; self.progress = progress; self.statusText = text }
    }
    private func fail(_ msg: String) {
        say("✗ " + msg)
        DispatchQueue.main.async { self.passed = false; self.busy = false; self.statusText = msg }
    }

    func check(project: String) {
        guard !busy else { return }
        busy = true; passed = nil; phase = 0; progress = 0; packages = []; conflict = nil; log = []
        DispatchQueue.global(qos: .userInitiated).async { self.run(project) }
    }

    private func run(_ project: String) {
        if ProjectStore.isImported(project) { return runImported(project) }
        let dir = ProjectStore.dir(project), fm = FileManager.default
        // ---- 1. Analyze：读清单、查格式版本、查文件齐全、查有没有不允许的文件
        set(phase: 0, progress: 0.1, text: tr("Reading manifest.json"))
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fail(tr("manifest.json is missing or not valid JSON")) }
        DispatchQueue.main.async { self.manifestText = String(data: data, encoding: .utf8) ?? "" }
        say(tr("Manifest read (%ld bytes)", data.count))
        guard let format = m["format"] as? Int, Builtin.supportedFormats.contains(format) else {
            return fail(tr("Unsupported manifest format %@ (this app reads %@)", "\(m["format"] ?? "?")", "\(Builtin.supportedFormats)")) }
        guard let kind = m["kind"] as? String, let requires = m["requires"] as? [String: String], let dataEntries = m["data"] as? [[String: String]] else {
            return fail(tr("Manifest is missing kind / requires / data")) }
        let files = m["files"] as? [String] ?? []
        let missing = files.filter { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard missing.isEmpty else { return fail(tr("Missing files: %@", missing.joined(separator: ", "))) }
        let bad = ((fm.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).filter { p in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: dir.appendingPathComponent(p).path, isDirectory: &isDir)
            return !isDir.boolValue && !Builtin.allowedExtensions.contains((p as NSString).pathExtension.lowercased()) }
        guard bad.isEmpty else { return fail(tr("Files that are not plain text are not allowed: %@", bad.joined(separator: ", "))) }
        say(tr("Format %ld OK · %ld files present · no executable files", format, files.count))
        set(phase: 1, progress: 0, text: tr("Resolving packages"))

        // ---- 2. Resolve：项目要的包版本 vs App 内置的版本
        var rows: [PackageRow] = [], problems: [String] = []
        for (name, need) in requires.sorted(by: { $0.key < $1.key }) {
            guard let have = Builtin.version(name) else { rows.append(PackageRow(name: name, required: need, have: "-", status: "Not available")); problems.append(tr("%@ is not available in this app", name)); continue }
            let ok = need.split(separator: ".").first == have.split(separator: ".").first     // 主版本号相同 = 兼容
            rows.append(PackageRow(name: name, required: need, have: have, status: name == "trainer-core" ? "Built-in" : (ok ? "Ready" : "Conflict")))
            if !ok { problems.append(tr("%@: project needs version %@, this app has %@", name, need, have)) }
        }
        DispatchQueue.main.async { self.packages = rows; self.conflict = problems.first }
        say(problems.isEmpty ? tr("All %ld required packages are compatible", rows.count) : tr("Conflict: %@", problems.joined(separator: "; ")))
        guard problems.isEmpty else { return fail(tr("Package conflict: %@", problems[0])) }
        set(phase: 2, progress: 0, text: tr("Preparing supported dependencies"))

        // ---- 3. Install：核对数据文件的 SHA256（和 App 里打包的数据一致才算数）
        let ds = Builtin.dataset
        guard m["dataset"] as? String == ds.name else { return fail(tr("Unknown dataset %@", "\(m["dataset"] ?? "?")")) }
        for (i, e) in dataEntries.enumerated() {
            guard let n = e["name"], let want = e["sha256"] else { return fail(tr("Bad data entry in manifest")) }
            guard let got = PackCheck.sha256(ofBundleFile: n) else { return fail(tr("Data file %@ not found", n)) }
            guard got == want, ds.files[n] == want else { return fail(tr("Data file %@ does not match its checksum", n)) }
            say(tr("SHA-256 OK: %@", n))
            set(phase: 2, progress: Double(i + 1) / Double(dataEntries.count), text: tr("Preparing supported dependencies"))
        }
        set(phase: 3, progress: 0, text: tr("Running a 3-step test"))

        // ---- 4. Test：真的跑 3 步试训练（GPU 和 CPU 各算一遍，看两边答案是否一致）
        if kind == "photos" {
            let blank = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { c in UIColor.gray.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
            guard FeatureExtractor.features(of: blank)?.count == featureDim else { return fail(tr("Photo feature model could not run")) }
            say(tr("Feature model produced %ld numbers for a test photo", featureDim))
        } else {
            let data = Dataset.shared
            let plan = Plan(seed: 1, hidden: 32, epochs: 1, trainCount: data.trainCount)
            let cpu = CPUNet(H: 32, lr: 0.05)
            guard let gpu = GPUNet(hidden: 32, lr: 0.05) else { return fail(tr("No Metal GPU on this device")) }
            var w = plan.initial
            for i in 0..<3 {
                let (x, y) = plan.batch(i, data)
                let ref = cpu.step(w, x, y)
                guard let g = gpu.step(w, x, y) else { return fail(tr("GPU step %ld returned nothing", i + 1)) }
                let d = max(updateMismatch(g.w1, ref.w1, w.w1), updateMismatch(g.w2, ref.w2, w.w2))
                guard d <= 1e-4, cpu.batchLoss(g, x, y).isFinite else { return fail(tr("Test step %ld: GPU and CPU disagree (%.1e)", i + 1, d)) }
                say(tr("Test step %ld: GPU and CPU agree (difference %.1e)", i + 1, d))
                w = g
                set(phase: 3, progress: Double(i + 1) / 3, text: tr("Running a 3-step test"))
            }
        }
        say(tr("✓ Project is ready"))
        DispatchQueue.main.async { self.phase = 4; self.progress = 1; self.passed = true; self.busy = false; self.statusText = tr("Project is ready") }
    }

    // MARK: 项目里的依赖分析（导入项目的「检查」和「Download & set up」共用）

    /// 读项目里的文本文件（每个 ≤ 300 KB，最多 300 个）
    static func textFiles(of project: String) -> [String: String] {
        let dir = ProjectStore.dir(project)
        var out: [String: String] = [:]
        for p in ((FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).sorted() where out.count < 300 {
            guard !p.hasPrefix("."), !p.hasPrefix("models/"), !p.hasPrefix("checkpoints/"), let d = try? Data(contentsOf: dir.appendingPathComponent(p)), d.count < 300_000,
                  let t = String(data: d, encoding: .utf8) else { continue }
            out[p] = t
        }
        return out
    }

    /// 把判定结果显示成包列表，并写日志；返回有冲突的说明
    private func show(_ verdicts: [PackageVerdict]) -> String? {
        let rows = verdicts.map { PackageRow(name: $0.name, required: $0.required.isEmpty ? "any" : $0.required, have: $0.have, status: $0.status, reason: $0.reason) }
        let conflict = verdicts.first { $0.status == "Conflict" }.map { tr("%@: project needs version %@, this app has %@", $0.name, $0.required, $0.have) }
        DispatchQueue.main.async { self.packages = rows; self.conflict = conflict }
        for v in verdicts { say("\(v.name) \(v.required): \(tr(v.status)) — \(tr(v.reason))") }
        return conflict
    }

    /// 从 GitHub 导入的项目：核对来源记录和每个文件的 SHA-256，列出依赖，看有没有「配方」，有就跑 3 步试训练
    private func runImported(_ project: String) {
        let dir = ProjectStore.dir(project)
        // ---- 1. Analyze：读来源记录和依赖文件
        set(phase: 0, progress: 0.1, text: tr("Reading the import record"))
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(".pt_import.json")),
              let rec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let files = rec["files"] as? [[String: Any]],
              let source = rec["source"] as? String else { return fail(tr("The import record is missing or damaged.")) }
        DispatchQueue.main.async { self.manifestText = String(data: data, encoding: .utf8) ?? "" }
        guard let host = URL(string: source)?.host, GitHubImport.hostAllowed(host) else { return fail(tr("The source address is not on the allowed list.")) }
        say(tr("Imported from %@ · %ld files · license %@", source, files.count, rec["license"] as? String ?? "unknown"))
        let reqs = DepScan.scan(files: EnvChecker.textFiles(of: project))
        say(tr("Found %ld packages in the dependency files and imports", reqs.count))
        // ---- 2. Resolve：每个包对照本 App 内置的组件
        set(phase: 1, progress: 0, text: tr("Resolving packages"))
        let verdicts = DepScan.resolve(reqs)
        _ = show(verdicts)
        let recipe = ProjectStore.recipePath(project)
        say(recipe.map { tr("Recipe found: %@", $0) } ?? tr("No recipe: this project can be read and edited, not run."))
        // ---- 3. Install：重新算每个文件的 SHA-256，和导入时记的对比（你改过的文件会被标出）
        set(phase: 2, progress: 0, text: tr("Checking files"))
        var edited = 0, missing = 0
        for (i, f) in files.enumerated() {
            guard let p = f["path"] as? String, let want = f["sha256"] as? String else { continue }
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(p)) else { missing += 1; continue }
            if SHA256.hash(data: d).map({ String(format: "%02x", $0) }).joined() != want { edited += 1 }
            set(phase: 2, progress: Double(i + 1) / Double(max(files.count, 1)), text: tr("Checking files"))
        }
        say(tr("SHA-256 checked: %ld files unchanged, %ld edited by you, %ld missing", files.count - edited - missing, edited, missing))
        finish(project: project, verdicts: verdicts, recipe: recipe)
    }

    /// 第 4 步 Test + 写环境报告（两条路共用）
    private func finish(project: String, verdicts: [PackageVerdict], recipe: String?) {
        set(phase: 3, progress: 0, text: tr("Running a 3-step test"))
        let coreml = !CoreMLTools.candidates(project: project).isEmpty
        let tables = !TabularTools.candidates(project: project).isEmpty
        if recipe != nil {
            let data = Dataset.shared
            let plan = Plan(seed: 1, hidden: 32, epochs: 1, trainCount: data.trainCount)
            let cpu = CPUNet(H: 32, lr: 0.05)
            guard let gpu = GPUNet(hidden: 32, lr: 0.05) else { return fail(tr("No Metal GPU on this device")) }
            var w = plan.initial
            for i in 0..<3 {
                let (x, y) = plan.batch(i, data)
                let ref = cpu.step(w, x, y)
                guard let g = gpu.step(w, x, y) else { return fail(tr("GPU step %ld returned nothing", i + 1)) }
                let d = max(updateMismatch(g.w1, ref.w1, w.w1), updateMismatch(g.w2, ref.w2, w.w2))
                guard d <= 1e-4 else { return fail(tr("Test step %ld: GPU and CPU disagree (%.1e)", i + 1, d)) }
                say(tr("Test step %ld: GPU and CPU agree (difference %.1e)", i + 1, d))
                w = g
            }
        } else if coreml || tables {
            say(coreml ? tr("A Core ML model was found: open the project and use Core ML model.") : tr("A data table was found: open the project and use Dataset."))
        } else { say(tr("Read & edit only — PocketTrainer runs recipes with its built-in trainer (not full Python or PyTorch).")) }
        let report = DepScan.report(recipe: recipe != nil || coreml || tables, verdicts: verdicts)
        EnvReport(state: report, packages: verdicts.map { EnvReport.Pkg(name: $0.name, required: $0.required, have: $0.have, status: $0.status, reason: $0.reason) },
                  recipe: recipe, coreml: coreml, tables: tables).save(project)
        let shown = report.hasPrefix("Missing: ") ? tr("Missing: %@", String(report.dropFirst(9))) : tr(report)
        say(tr("✓ Project is ready") + " — " + shown)
        DispatchQueue.main.async { self.phase = 4; self.progress = 1; self.passed = true; self.busy = false; self.statusText = shown }
    }

    // MARK: Download & set up：列文件 → 下载依赖文件并分析 → 对照 → 下载其余文本 → 试训

    func setup(url: String, store: ProjectStore, done: @escaping (String?) -> Void) {
        guard !busy else { return }
        busy = true; passed = nil; phase = 0; progress = 0; packages = []; conflict = nil; log = []
        Task.detached { await self.runSetup(url: url, store: store, done: done) }
    }

    private func runSetup(url: String, store: ProjectStore, done: @escaping (String?) -> Void) async {
        do {
            // ---- 1. Analyze：列出文件；先下载「依赖文件 + .py」放在内存里分析
            set(phase: 0, progress: 0.05, text: tr("Listing the files"))
            var plan = try await GitHubImport.plan(url: url) { self.say($0) }
            say(tr("Found %ld text files and %ld model/data files (license: %@)", plan.want.count, plan.weights.count, plan.license ?? tr("not stated")))
            var cache: [String: Data] = [:], skipped = plan.skipped
            let first = plan.want.filter { w in
                let n = (w.path as NSString).lastPathComponent.lowercased()
                return w.path.hasSuffix(".py") || n.hasPrefix("requirements") || ["pyproject.toml", "setup.py", "setup.cfg", "environment.yml", "environment.yaml"].contains(n)
            }
            for (i, f) in first.enumerated() {
                set(phase: 0, progress: Double(i + 1) / Double(max(first.count, 1)), text: tr("Reading dependency files and code"))
                if let d = try await GitHubImport.fetch(plan, f.path, skipped: &skipped) { cache[f.path] = d }
            }
            let texts = cache.compactMapValues { String(data: $0, encoding: .utf8) }
            let reqs = DepScan.scan(files: texts)
            say(tr("Found %ld packages in the dependency files and imports", reqs.count))
            // ---- 2. Resolve
            set(phase: 1, progress: 0, text: tr("Resolving packages"))
            let verdicts = DepScan.resolve(reqs)
            _ = show(verdicts)
            // ---- 3. Install：把所有允许的文本文件下载进新项目（权重只列出，不下载）
            set(phase: 2, progress: 0, text: tr("Downloading files"))
            plan.skipped = skipped
            let sum = try await GitHubImport.install(plan, cache: cache, store: store) { s in
                self.say(s)
                let n = s.split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Double($0) }      // 「第 3 个，共 10 个」里的两个数
                if n.count == 2 { self.set(phase: 2, progress: n[0] / max(n[1], 1), text: tr("Downloading files")) }
            }
            say(tr("Saved %ld files (%.1f KB) into the project “%@”", sum.files.count, Double(sum.bytes) / 1024, sum.project))
            if !sum.weights.isEmpty { say(tr("%ld model/data files are listed but not downloaded. Download them one by one in the project (max 50 MB each).", sum.weights.count)) }
            if !sum.skipped.isEmpty { say(tr("%ld files were skipped at import time (not plain text, too large or not allowed).", sum.skipped.count)) }
            DispatchQueue.main.async { self.manifestText = (try? String(contentsOf: ProjectStore.dir(sum.project).appendingPathComponent(".pt_import.json"), encoding: .utf8)) ?? "" }
            finish(project: sum.project, verdicts: verdicts, recipe: ProjectStore.recipePath(sum.project))
            DispatchQueue.main.async { done(sum.project) }
        } catch let e {
            fail(e.localizedDescription)
            DispatchQueue.main.async { done(nil) }
        }
    }
}

/// 项目的环境报告（写在 .pt_env.json，编辑器顶部的小卡片读它）
struct EnvReport: Codable {
    struct Pkg: Codable { var name: String, required: String, have: String, status: String, reason: String }
    var state: String                 // Ready to run / Read & edit only / Missing: …
    var packages: [Pkg]
    var recipe: String?
    var coreml: Bool
    var tables: Bool

    func save(_ project: String) { try? JSONEncoder().encode(self).write(to: ProjectStore.dir(project).appendingPathComponent(".pt_env.json")) }
    static func load(_ project: String) -> EnvReport? {
        (try? Data(contentsOf: ProjectStore.dir(project).appendingPathComponent(".pt_env.json"))).flatMap { try? JSONDecoder().decode(EnvReport.self, from: $0) }
    }
}
