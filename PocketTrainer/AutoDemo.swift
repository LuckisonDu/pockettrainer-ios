// AutoDemo.swift —— 真机自动验证用的启动参数（界面上不出现）：
//   --auto-demo=search --q=<词> --source=github|hf|hfDataset     → Documents/search.json
//   --auto-demo=setup --url=<GitHub/HF 链接>                      → Documents/setup.json
//   --auto-demo=coreml --repo=<HF 模型 id>                        → Documents/coreml.json
//   --auto-demo=dataset --repo=<HF 数据集 id>                     → Documents/dataset.json
//   --auto-demo=export                                            → Documents/export.json（用默认项目最新存档导出 Core ML + safetensors，并在手机上用导出的模型重新预测对拍；先要跑过一次训练）
import Foundation
import CoreML
import UIKit

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

// MARK: - 开放数据 + 结果页 + 生成器（真机自动验证）
//   --auto-demo=opendata --data=<目录里的 id>   → Documents/opendata.json（下载 → 训练 → 结果页同样的计算）
//   --auto-demo=gen --data=mnist                → Documents/gen.json + gen_samples.png（生成器项目：下载 → 训练 → 画图；有 MNIST 分类器时用它核对「画的是不是要的数字」）
extension AutoDemo {
    static func recipe(_ p: String) -> (h: Int, lr: Double, e: Int) {
        let m = FileStore.read(p, ProjectStore.recipePath(p) ?? "code/model.py")
        return (Int(ConfigCode.value("hidden_units", in: m) ?? "") ?? 128, Double(ConfigCode.value("learning_rate", in: m) ?? "") ?? 0.1, Int(ConfigCode.value("epochs", in: m) ?? "") ?? 10)
    }

    static func openData(id: String, store: ProjectStore, trainer: Trainer, router: Router) {
        remove("opendata.json")
        Task {
            let t0 = Date(); var out: [String: Any] = ["data": id]
            do {
                guard let ds = OpenDataset.catalog.first(where: { $0.id == id }) else { throw ProjectData.Failure(errorDescription: "unknown data id") }
                let name = "Open data " + ds.id
                let p = store.projects.contains { $0.name == name } ? name : store.create(Template.all[0], name: name)
                router.path = [.editor(p)]
                let src = try await ProjectData.download(ds, project: p) { _, _, _ in }
                out["downloadSeconds"] = -t0.timeIntervalSinceNow; out["count"] = src.count; out["classes"] = src.classes; out["license"] = src.license
                out["dataFiles"] = (try? FileManager.default.contentsOfDirectory(atPath: ProjectData.dir(p).path))?.sorted() ?? []
                ProjectData.applySuggested(ds, trainRows: src.count - max(5, src.count / 5), project: p)
                let r = recipe(p); out["recipe"] = ["hidden": r.h, "lr": r.lr, "epochs": r.e]
                trainer.lr = r.lr; trainer.hidden = r.h; trainer.epochs = r.e; trainer.seed = 1; trainer.protect = true
                trainer.dataset = try ProjectData.trainingDataset(project: p); trainer.currentProject = p
                trainer.start()
                while trainer.running { try? await Task.sleep(nanoseconds: 300_000_000) }
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let r = trainer.result { out["accuracy"] = r.accuracy; out["cpuReferenceAccuracy"] = r.refAccuracy; out["steps"] = r.totalSteps; out["flaggedSteps"] = r.flaggedSteps; out["trainSeconds"] = r.seconds }
                out["stamp"] = ProjectData.trainedOn(p); out["dataKey"] = ProjectData.dataKey(p)
                if let ck = ProjectStore.latestCheckpoint(p), let c = CoreMLExport.loadCheckpoint(ck.url) {
                    let l = try ClassifierResult.compute(project: p, weights: c.weights, hidden: c.hidden, step: c.step)
                    out["resultAccuracy"] = l.accuracy; out["resultItems"] = l.items.count; out["resultMs"] = l.ms
                    out["resultCorrect"] = l.items.filter { $0.pred == $0.truth }.count
                    out["resultFirst"] = l.items.prefix(8).map { "\(l.classes[safe: $0.pred] ?? "?") \(Int($0.conf * 100))% (answer \(l.classes[safe: $0.truth] ?? "?"))" }
                }
                out["log"] = Array(trainer.log.suffix(4))
            } catch let e { out["error"] = e.localizedDescription }
            out["seconds"] = -t0.timeIntervalSinceNow; write("opendata.json", out)
        }
    }

    static func generator(id: String, store: ProjectStore, router: Router) {
        remove("gen.json")
        Task {
            let t0 = Date(); var out: [String: Any] = ["data": id]
            do {
                guard let ds = OpenDataset.catalog.first(where: { $0.id == id && $0.kind == .images }) else { throw ProjectData.Failure(errorDescription: "not a picture dataset") }
                let g = Template.all.first { $0.id == "generator" }!
                let p = store.projects.first { $0.kind == "generator" }?.name ?? store.create(g, name: g.title)
                out["project"] = p
                router.path = [.editor(p)]
                if ProjectData.source(p)?.id != ds.id {
                    let src = try await ProjectData.download(ds, project: p) { _, _, _ in }
                    out["downloadSeconds"] = -t0.timeIntervalSinceNow; out["count"] = src.count
                }
                let r = recipe(p); out["recipe"] = ["hidden": r.h, "lr": r.lr, "epochs": r.e]
                let gen = GenTrainer.shared
                try gen.start(project: p, hidden: r.h, lr: r.lr, epochs: r.e, seed: 1)
                while gen.running { try? await Task.sleep(nanoseconds: 300_000_000) }
                out["info"] = GenTrainer.info(p) ?? [:]
                out["lossFirst"] = gen.lossPoints.first?.train ?? -1; out["lossLast"] = gen.lossPoints.last?.train ?? -1; out["valLast"] = gen.lossPoints.last?.val ?? -1
                out["log"] = Array(gen.log.suffix(3))
                guard let m = GenTrainer.load(p) else { throw ProjectData.Failure(errorDescription: "no saved generator") }
                // 每类 8 张 → 拼成一张图存 Documents/gen_samples.png
                var rng = LCG(seed: 42), all: [[UInt8]] = []
                for c in 0..<CVAE.C { all += m.generate(label: c, count: 8, rng: &rng) }
                var big = [UInt8](repeating: 0, count: 28 * 8 * 28 * 10)
                for (k, s) in all.enumerated() { let (gr, gc) = (k / 8, k % 8); for y in 0..<28 { for x in 0..<28 { big[(gr * 28 + y) * 224 + gc * 28 + x] = s[y * 28 + x] } } }
                if let img = grayImage(big, w: 224, h: 280), let png = img.pngData() { try? png.write(to: Store.docs.appendingPathComponent("gen_samples.png")) }
                // 有用 MNIST 训练过的分类器：让它认生成的图，看是不是要的那个数字
                let clf = "Open data " + ds.id
                if let ck = ProjectStore.latestCheckpoint(clf), let c = CoreMLExport.loadCheckpoint(ck.url), ProjectData.trainedOn(clf) == "hf:" + ds.id {
                    var x = [Float](repeating: 0, count: all.count * featureDim)
                    for (k, s) in all.enumerated() { for j in 0..<784 { x[k * featureDim + j] = Float(s[j]) / 255 } }
                    let z = CPUNet(H: c.hidden, lr: 0).logits(c.weights, x, all.count)
                    var hit = 0
                    for k in all.indices { let row = Array(z[(k * numClasses)..<((k + 1) * numClasses)]); if row.firstIndex(of: row.max()!) == k / 8 { hit += 1 } }
                    out["classifierAgrees"] = Double(hit) / Double(all.count); out["classifierProject"] = clf
                }
                // 结果页「复制一张图」：重建误差
                if let im = ProjectData.images(p) {
                    let test = Array(ProjectData.split(im.count).test.prefix(100))
                    let (x, _) = GenTrainer.batch(im, test)
                    let rec = m.reconstruct(x, label: test.map { Int(im.labels[$0]) })
                    var err = 0.0; for (i, r) in rec.enumerated() { for j in 0..<784 { err += abs(Double(r[j]) / 255 - Double(x[i * 784 + j])) } }
                    out["reconstructMAE"] = err / Double(rec.count * 784)
                }
            } catch let e { out["error"] = e.localizedDescription }
            out["seconds"] = -t0.timeIntervalSinceNow; write("gen.json", out)
        }
    }

    static func grayImage(_ px: [UInt8], w: Int, h: Int) -> UIImage? {
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
