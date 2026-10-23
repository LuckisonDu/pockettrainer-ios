// AutoDemo.swift —— 真机自动验证用的启动参数（界面上不出现）：
//   --auto-demo=search --q=<词> --source=github|hf|hfDataset     → Documents/search.json
//   --auto-demo=setup --url=<GitHub/HF 链接>                      → Documents/setup.json
//   --auto-demo=coreml --repo=<HF 模型 id>                        → Documents/coreml.json
//   --auto-demo=dataset --repo=<HF 数据集 id>                     → Documents/dataset.json
//   --auto-demo=export                                            → Documents/export.json（用默认项目最新存档导出 Core ML + safetensors，并在手机上用导出的模型重新预测对拍；先要跑过一次训练）
import Foundation
import CoreML

@MainActor
enum AutoDemo {
    static func write(_ name: String, _ obj: [String: Any]) {
        try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: Store.docs.appendingPathComponent(name))
    }
    static func remove(_ name: String) { try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent(name)) }

    /// 导出 Core ML + safetensors 并在手机上验证（CPU 与 all 两种计算单元），结果写 export.json
    static func exportCheck() {
        remove("export.json")
        Task.detached(priority: .userInitiated) {
            var out: [String: Any] = [:]
            let t0 = Date()
            if let ck = ProjectStore.latestCheckpoint(ProjectStore.defaultProject), let c = CoreMLExport.loadCheckpoint(ck.url) {
                out["step"] = c.step; out["hidden"] = c.hidden; out["weightsHash"] = Store.hash(c.weights)
                do {
                    let dir = ProjectStore.dir(ProjectStore.defaultProject).appendingPathComponent("export", isDirectory: true)
                    let r = try CoreMLExport.export(c.weights, hidden: c.hidden, to: dir, note: "PocketTrainer auto export")
                    out["mlmodelBytes"] = (try? Data(contentsOf: r.modelURL).count) ?? -1; out["safetensorsBytes"] = (try? Data(contentsOf: r.safetensorsURL).count) ?? -1
                    var vs: [[String: Any]] = []
                    for u in [MLComputeUnits.cpuOnly, .cpuAndGPU, .all] {
                        let v = try CoreMLExport.verify(c.weights, hidden: c.hidden, modelURL: r.modelURL, data: Dataset.shared, rows: 2000, units: u)
                        vs.append(["units": v.computeUnits, "rows": v.rows, "coreMLAccuracy": v.coreMLAccuracy, "cpuAccuracy": v.cpuAccuracy, "maxAbsDiff": Double(v.maxAbsDiff), "sameTop1": v.sameTop1])
                    }
                    out["verify"] = vs
                } catch let e { out["error"] = "\(e)" }
            } else { out["error"] = "no checkpoint (train first)" }
            out["seconds"] = -t0.timeIntervalSinceNow
            await MainActor.run { write("export.json", out) }
        }
    }

    static func search(q: String, source: String) {
        remove("search.json")
        Task {
            let t0 = Date(); var out: [String: Any] = ["q": q, "source": source]
            do { let hits = try await SearchAPI.search(source: source, query: q)
                out["count"] = hits.count; out["first"] = hits.prefix(5).map { "\($0.id) [\($0.license ?? "no license")] stars=\($0.stars ?? -1) downloads=\($0.downloads ?? -1)" }
                SearchAPI.save(hits, source: source, query: q)
            } catch let e { out["error"] = e.localizedDescription; out["cachedCount"] = SearchAPI.cached(source: source, query: q)?.count ?? 0 }
            out["seconds"] = -t0.timeIntervalSinceNow; write("search.json", out)
        }
    }

    /// 跑一遍 Download & set up，等它结束，返回项目名
    private static func setupAndWait(url: String, store: ProjectStore) async -> String? {
        var name: String?
        EnvChecker.shared.setup(url: url, store: store) { name = $0 }
        while EnvChecker.shared.busy { try? await Task.sleep(nanoseconds: 300_000_000) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        return name
    }

    static func setup(url: String, store: ProjectStore) {
        remove("setup.json")
        Task {
            let t0 = Date(); var out: [String: Any] = ["url": url]
            let env = EnvChecker.shared
            if let p = await setupAndWait(url: url, store: store) {
                out["project"] = p
                if let d = try? Data(contentsOf: ProjectStore.dir(p).appendingPathComponent(".pt_import.json")), let rec = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    let files = rec["files"] as? [[String: Any]] ?? []
                    out["files"] = files.count; out["bytes"] = files.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
                    out["skipped"] = (rec["skipped"] as? [[String: String]] ?? []).map { "\($0["path"] ?? "") (\($0["reason"] ?? ""))" }
                    out["weightsListed"] = (rec["weights"] as? [[String: Any]] ?? []).map { "\($0["path"] ?? "") \($0["size"] ?? 0)" }
                    out["license"] = rec["license"] ?? "unknown"
                }
                if let r = EnvReport.load(p) { out["report"] = r.state; out["recipe"] = r.recipe ?? "none"; out["coremlFound"] = r.coreml; out["tablesFound"] = r.tables
                    out["packages"] = r.packages.map { "\($0.name) \($0.required) → \($0.status)" } }
            }
            out["passed"] = env.passed ?? false; out["status"] = env.statusText; out["log"] = env.log; out["seconds"] = -t0.timeIntervalSinceNow
            write("setup.json", out)
        }
    }

    static func coreml(repo: String, model: String?, store: ProjectStore) {
        remove("coreml.json")
        Task {
            let t0 = Date(); var out: [String: Any] = ["repo": repo]
            do {
                guard let p = await setupAndWait(url: "https://huggingface.co/" + repo, store: store) else { throw CoreMLTools.Failure(errorDescription: EnvChecker.shared.statusText) }
                out["project"] = p
                let all = CoreMLTools.candidates(project: p)
                out["candidates"] = all.map { "\($0.name) \($0.size)" }
                guard let c = (model.flatMap { m in all.first { $0.name.contains(m) } } ?? all.first) else { throw CoreMLTools.Failure(errorDescription: "No runnable Core ML model found") }
                out["model"] = c.name; out["downloadBytes"] = c.size
                let t1 = Date()
                let url = try await CoreMLTools.prepare(c, project: p) { _, _ in }
                out["prepareSeconds"] = -t1.timeIntervalSinceNow     // 下载 + 编译
                out["description"] = CoreMLTools.describe(url)
                let img = CoreMLTools.sampleImage()
                let g = try CoreMLTools.predict(url, image: img, units: .cpuAndGPU), cpu = try CoreMLTools.predict(url, image: img, units: .cpuOnly)
                let cmp = CoreMLTools.compare(g.vector, cpu.vector)
                out["top5"] = g.top.map { "\($0.label) \(String(format: "%.4f", $0.p))" }; out["cpuTop5"] = cpu.top.map { "\($0.label) \(String(format: "%.4f", $0.p))" }
                if g.top.first?.label.hasPrefix("#") == true {       // 输出是向量：当作「Teach it your photos」的特征提取器试一下
                    UserDefaults.standard.set(String(url.path.dropFirst(Store.docs.path.count + 1)), forKey: FeatureExtractor.customKey)
                    TeachSelfTest.run()
                    UserDefaults.standard.removeObject(forKey: FeatureExtractor.customKey)
                    if let d = try? Data(contentsOf: Store.docs.appendingPathComponent("teach_selftest.json")), let j = try? JSONSerialization.jsonObject(with: d) { out["teachSelfTestWithThisModel"] = j }
                }
                out["cosine"] = cmp.cos; out["maxDiff"] = cmp.maxDiff; out["verified"] = cmp.ok; out["gpuSeconds"] = g.seconds; out["cpuSeconds"] = cpu.seconds
            } catch let e { out["error"] = e.localizedDescription }
            out["seconds"] = -t0.timeIntervalSinceNow; write("coreml.json", out)
        }
    }

    static func dataset(repo: String, store: ProjectStore, trainer: Trainer) {
        remove("dataset.json")
        Task {
            let t0 = Date(); var out: [String: Any] = ["repo": repo]
            do {
                guard let p = await setupAndWait(url: "https://huggingface.co/datasets/" + repo, store: store) else { throw TabularTools.Failure(errorDescription: EnvChecker.shared.statusText) }
                out["project"] = p
                guard let rel0 = TabularTools.candidates(project: p).first else { throw TabularTools.Failure(errorDescription: "No table (csv/jsonl) found") }
                var rel = rel0
                if !FileManager.default.fileExists(atPath: ProjectStore.dir(p).appendingPathComponent(rel).path) { throw TabularTools.Failure(errorDescription: "Table is larger than 512 KB and was only listed") }
                if ProjectStore.dir(p).appendingPathComponent(rel).path.isEmpty { rel = rel0 }
                let t = try TabularTools.load(project: p, rel: rel)
                let li = TabularTools.guessLabel(t)
                let feats = t.columns.indices.filter { t.numeric[$0] && $0 != li && !["id", "Id", "ID"].contains(t.columns[$0]) }.map { t.columns[$0] }
                TabularTools.saveConfig(.init(file: rel, label: t.columns[li], features: feats), project: p)
                FileStore.write(p, "code/model.py", "# PocketTrainer recipe for a table dataset\nhidden_units = 32\nlearning_rate = 0.1\nepochs = 200\nseed = 1\n")
                let (ds, classes) = try TabularTools.buildDataset(project: p)
                out["file"] = rel; out["rows"] = t.rows.count; out["columns"] = t.columns; out["label"] = t.columns[li]; out["features"] = feats; out["classes"] = classes
                trainer.dataset = ds; trainer.currentProject = p; trainer.lr = 0.1; trainer.hidden = 32; trainer.epochs = 200; trainer.seed = 1; trainer.protect = true
                trainer.start()
                while trainer.running { try? await Task.sleep(nanoseconds: 300_000_000) }
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let r = trainer.result { out["accuracy"] = r.accuracy; out["cpuReferenceAccuracy"] = r.refAccuracy; out["steps"] = r.totalSteps; out["flaggedSteps"] = r.flaggedSteps; out["trainSeconds"] = r.seconds }
                out["log"] = Array(trainer.log.suffix(6))
            } catch let e { out["error"] = e.localizedDescription }
            out["seconds"] = -t0.timeIntervalSinceNow; write("dataset.json", out)
        }
    }
}
