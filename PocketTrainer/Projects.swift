// Projects.swift —— 项目 = 沙盒里 Documents/Projects/<名字>/ 下的一个文件夹
// 里面有 code/ models/ data/ checkpoints/ notes/ results/ 和 README.md、manifest.json（「项目包」清单）
import Foundation

struct ProjectInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let kind: String          // "cifar" = 用内置训练器；"photos" = 用自己的照片教它
    let lastOpened: Date?
}

/// 内置的项目模板
struct Template: Identifiable {
    let id: String, title: String, kind: String
    let hidden: Int, lr: Double, epochs: Int
    let blurb: String

    static let all = [
        Template(id: "cifar", title: "Photo classifier (CIFAR-10)", kind: "cifar", hidden: 512, lr: 0.05, epochs: 8,
                 blurb: "Train a small AI to recognise 10 kinds of photos."),
        Template(id: "photos", title: "Teach it your photos", kind: "photos", hidden: 0, lr: 0, epochs: 0,
                 blurb: "Show it about 15 photos of 3 things and it learns them."),
        Template(id: "lab", title: "Learning-rate lab", kind: "cifar", hidden: 128, lr: 0.2, epochs: 6,
                 blurb: "Change the learning rate and watch what happens."),
        Template(id: "generator", title: "Picture generator", kind: "generator", hidden: 400, lr: 0.001, epochs: 40,
                 blurb: "Train a small AI that draws new pictures, like handwritten digits."),
    ]
}

final class ProjectStore: ObservableObject {
    static let defaultProject = "Photo classifier (CIFAR-10)"
    static let root = Store.docs.appendingPathComponent("Projects", isDirectory: true)
    static func dir(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    @Published var projects: [ProjectInfo] = []

    init() { ensureTemplates(); reload() }

    // MARK: 列表

    func reload() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: Self.root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let dates = UserDefaults.standard.dictionary(forKey: "lastOpened") as? [String: Double] ?? [:]
        projects = names.map { n in
            let kind = Self.isImported(n) ? "import" : (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.dir(n).appendingPathComponent("manifest.json"))) as? [String: Any])?["kind"] as? String ?? "cifar"
            return ProjectInfo(name: n, kind: kind, lastOpened: dates[n].map { Date(timeIntervalSince1970: $0) })
        }.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    }

    /// 是不是从 GitHub 导入的项目（导入时会留一份来源记录）
    static func isImported(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir(name).appendingPathComponent(".pt_import.json").path) }

    /// 项目里的「PocketTrainer 配方」文件：code/model.py，或最浅的 model.py；里面要有 hidden_units / learning_rate / epochs 三个数字
    static func recipePath(_ name: String) -> String? {
        let root = dir(name)
        var cands = ["code/model.py"]
        let all = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
        cands += all.filter { ($0 as NSString).lastPathComponent == "model.py" }.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        return cands.first { rel in
            guard let t = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) else { return false }
            return Int(ConfigCode.value("hidden_units", in: t) ?? "") != nil && Double(ConfigCode.value("learning_rate", in: t) ?? "") != nil && Int(ConfigCode.value("epochs", in: t) ?? "") != nil
        }
    }

    func touch(_ name: String) {
        var d = UserDefaults.standard.dictionary(forKey: "lastOpened") as? [String: Double] ?? [:]
        d[name] = Date().timeIntervalSince1970
        UserDefaults.standard.set(d, forKey: "lastOpened"); reload()
    }

    /// 第一次启动：把三个模板都建成项目
    private func ensureTemplates() {
        defer { UserDefaults.standard.set(true, forKey: "tplGenerator") }
        guard FileManager.default.fileExists(atPath: Self.root.path) else { for t in Template.all { _ = create(t, name: t.title) }; return }
        // 老用户升级：只补一次新加的「Picture generator」模板（删了就不再补）
        if !UserDefaults.standard.bool(forKey: "tplGenerator"), let g = Template.all.first(where: { $0.id == "generator" }) { _ = create(g, name: g.title) }
    }

    // MARK: 新建 / 删除

    @discardableResult
    func create(_ t: Template, name: String) -> String {
        let fm = FileManager.default
        var final = name, k = 2
        while fm.fileExists(atPath: Self.dir(final).path) { final = "\(name) \(k)"; k += 1 }
        let d = Self.dir(final)
        for sub in ["code", "models", "data", "checkpoints", "notes", "results"] { try? fm.createDirectory(at: d.appendingPathComponent(sub), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) { try? text.write(to: d.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        write("code/model.py", Self.modelPy(t))
        write("code/train.py", Self.trainPy)
        write("code/config.json", "{\n  \"project\": \"\(final)\",\n  \"kind\": \"\(t.kind)\"\n}\n")
        write("notes/learning-notes.md", "# Learning notes\n\nWrite what you tried and what happened.\n")
        write("README.md", "# \(final)\n\n\(t.blurb)\n\nOpen `code/model.py`, change the numbers, press Run.\n")
        write("manifest.json", PackCheck.builtinManifest(title: final, kind: t.kind))
        reload()
        return final
    }

    func delete(_ name: String) { try? FileManager.default.removeItem(at: Self.dir(name)); reload() }

    /// 项目占多少磁盘（字节）
    static func size(_ name: String) -> Int {
        let e = FileManager.default.enumerator(at: dir(name), includingPropertiesForKeys: [.fileSizeKey])
        return (e?.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } } ?? []).reduce(0, +)
    }

    // MARK: 检查点文件

    /// 项目里最新的检查点：(步数, 文件)。文件名 step_000162.ckpt
    static func latestCheckpoint(_ project: String) -> (step: Int, url: URL)? {
        let dir = dir(project).appendingPathComponent("checkpoints")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("step_") && $0.hasSuffix(".ckpt") }.sorted()
        guard let f = files.last, let n = Int(f.dropFirst(5).dropLast(5)) else { return nil }
        return (n, dir.appendingPathComponent(f))
    }

    /// 训练结束：把最终权重存成 checkpoints/step_NNNNNN.ckpt（只留最近 3 个）
    static func saveFinalCheckpoint(_ w: Weights, step: Int, project: String) {
        let dir = dir(project).appendingPathComponent("checkpoints")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Store.pack(w, step: step).write(to: dir.appendingPathComponent(String(format: "step_%06d.ckpt", step)), options: .atomic)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".ckpt") }.sorted()
        for f in files.dropLast(3) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }

    // MARK: 模板里的代码文本

    static func modelPy(_ t: Template) -> String {
        if t.kind == "generator" {
            return """
            # Picture generator: a small conditional VAE, trained on this phone
            # PocketTrainer reads these four lines.
            hidden_units = \(t.hidden)
            learning_rate = \(t.lr)
            epochs = \(t.epochs)
            seed = 1

            # The model (shown for learning):
            # encoder: picture (28x28 = 784) + class (10) -> hidden_units (ReLU) -> 2 "style" numbers
            # decoder: 2 style numbers + class (10) -> hidden_units (ReLU) -> picture (784)
            # After training: pick a class + 2 random numbers -> a new picture.

            """
        }
        if t.kind == "photos" {
            return """
            # Teach it your photos (PocketTrainer runs this with its built-in photo teacher)
            classes = 3
            photos_per_class = 15
            # Features: 2048 numbers per photo from ResNet50 (computed on this phone).
            # Classifier: 2048 -> 3 classes, trained on the phone's CPU.

            """
        }
        return """
        # Model configuration
        # PocketTrainer reads these four lines.
        hidden_units = \(t.hidden)
        learning_rate = \(t.lr)
        epochs = \(t.epochs)
        seed = 1

        # The model (shown for learning):
        # 2048 photo features -> hidden_units (ReLU) -> 10 classes

        """
    }

    static let trainPy = """
    # train.py: what the built-in trainer does (shown for learning, not run as Python)
    for step in range(total_steps):
        batch = next_batch(128)
        new_weights = gpu_step(weights, batch)
        if verify_training_results:          # Settings > Training
            shadow = cpu_step(weights, batch)
            if differs(new_weights, shadow):
                new_weights = recompute_on_gpu(weights, batch)
        weights = new_weights
        if save_checkpoints and step % checkpoint_interval == 0:
            save_checkpoint(weights)          # atomic: write .tmp, then replace

    """
}
