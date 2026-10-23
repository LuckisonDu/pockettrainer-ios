// RecipeMap.swift —— 「Map to recipe」：在导入的代码里找 learning_rate / lr / epochs / hidden… 的赋值，
// 一键把数值抄进 model.py 的「配方」几行。只读文字、只改配方，不运行原来的代码。
import SwiftUI

struct RecipeCandidate: Identifiable {
    let id = UUID()
    let file: String, line: Int, name: String, value: String
    let key: String          // 对应的配方键
    var valid: Bool {        // 数值在 PocketTrainer 能跑的范围内吗
        switch key {
        case "learning_rate": return Double(value).map { (0.001...1.0).contains($0) } ?? false
        case "epochs": return Int(value).map { (1...300).contains($0) } ?? false
        default: return Int(value).map { (8...1024).contains($0) } ?? false
        }
    }
}

enum RecipeMap {
    static let keyFor: [String: String] = ["learning_rate": "learning_rate", "lr": "learning_rate",
        "epochs": "epochs", "n_epochs": "epochs", "num_epochs": "epochs", "max_epochs": "epochs",
        "hidden_units": "hidden_units", "hidden_size": "hidden_units", "hidden_dim": "hidden_units", "n_hidden": "hidden_units", "num_hidden": "hidden_units", "hidden": "hidden_units"]
    private static let re = try! NSRegularExpression(pattern: "\\b(learning_rate|lr|epochs|n_epochs|num_epochs|max_epochs|hidden_units|hidden_size|hidden_dim|n_hidden|num_hidden|hidden)\\b\\s*(?::[^=\\n]+)?[=:]\\s*(?:float\\(|int\\()?(-?[0-9]*\\.?[0-9]+(?:e-?[0-9]+)?)")

    /// 扫描项目里的 .py 文件（最多 60 个）
    static func scan(_ project: String) -> [RecipeCandidate] {
        let root = ProjectStore.dir(project)
        let files = ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).filter { $0.hasSuffix(".py") }.sorted().prefix(60)
        var out: [RecipeCandidate] = []
        for f in files {
            guard let t = try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) else { continue }
            for (i, line) in t.components(separatedBy: "\n").enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let n = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line), let key = keyFor[String(line[n])] else { continue }
                out.append(RecipeCandidate(file: f, line: i + 1, name: String(line[n]), value: String(line[v]), key: key))
            }
        }
        return Array(out.prefix(60))
    }

    /// 把值写进配方文件（没有就新建 code/model.py，里面带齐四个键的默认值）
    static func apply(_ c: RecipeCandidate, project: String) {
        let path = ProjectStore.recipePath(project) ?? "code/model.py"
        var text = FileStore.read(project, path)
        if ProjectStore.recipePath(project) == nil {
            text = "# PocketTrainer recipe (made by \"Map to recipe\")\n# The built-in trainer reads these four lines.\nhidden_units = 128\nlearning_rate = 0.01\nepochs = 10\nseed = 1\n"
            try? FileManager.default.createDirectory(at: ProjectStore.dir(project).appendingPathComponent("code"), withIntermediateDirectories: true)
        }
        FileStore.write(project, path, ConfigCode.set(c.key, c.value, in: text))
    }
}

struct MapRecipeSheet: View {
    let project: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RecipeCandidate] = []
    @State private var done: Set<UUID> = []
    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Only the recipe lines in model.py are changed. The imported code is never run.")) {
                    if items.isEmpty { Text("No learning rate, epochs or hidden size found in the code.").foregroundColor(.secondary) }
                    ForEach(items) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.name) = \(c.value)").font(.system(.subheadline, design: .monospaced))
                                Text("\((c.file as NSString).lastPathComponent):\(c.line) → \(c.key)").font(.caption).foregroundColor(.secondary)
                                if !c.valid { Text("Outside the range PocketTrainer can run").font(.caption2).foregroundColor(.orange) }
                            }
                            Spacer()
                            Button(done.contains(c.id) ? "Done" : "Use") { RecipeMap.apply(c, project: project); done.insert(c.id) }
                                .buttonStyle(.bordered).tint(.teal).disabled(!c.valid || done.contains(c.id))
                        }
                    }
                }
            }
            .navigationTitle("Map to recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { items = RecipeMap.scan(project) }
        }
    }
}
