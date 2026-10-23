// ProjectTools.swift —— 导入项目页上的小工具：环境报告卡、模型/数据文件列表、表格数据集（Dataset）页
import SwiftUI

/// 导入的项目，在编辑器顶部显示：环境报告 + 能做什么
struct ProjectToolsCard: View {
    let project: String
    var body: some View {
        let r = EnvReport.load(project)
        Card {
            Text("Environment report").font(.subheadline.bold())
            if let r {
                let ready = r.state == "Ready to run"
                Label(tr(r.state.hasPrefix("Missing:") ? "Missing: %@" : r.state, String(r.state.dropFirst(9))), systemImage: ready ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
                    .font(.footnote.bold()).foregroundColor(ready ? .green : .orange)
                let bad = r.packages.filter { $0.status != "Built-in" }
                if !bad.isEmpty { Text(tr("Not available on iOS: %@", bad.prefix(8).map(\.name).joined(separator: ", "))).font(.caption).foregroundColor(.secondary) }
                if r.packages.contains(where: { $0.reason.contains("native") }) { Text("needs native code that iOS apps cannot download").font(.caption2).foregroundColor(.secondary) }
            } else { Text("Open the Environment tab and press Check again.").font(.footnote).foregroundColor(.secondary) }
            NavigationLink { ModelFilesView(project: project) } label: { Label("Model & data files", systemImage: "shippingbox") }
            if !CoreMLTools.candidates(project: project).isEmpty { NavigationLink { CoreMLView(project: project) } label: { Label("Core ML model", systemImage: "cpu") } }
            if !TabularTools.candidates(project: project).isEmpty { NavigationLink { TabularView(project: project) } label: { Label("Dataset", systemImage: "tablecells") } }
        }
    }
}

/// 导入记录里列出的模型/数据文件：用户逐个点才下载（≤ 50 MB），下载后只存放；safetensors 显示张量名和形状
struct ModelFilesView: View {
    let project: String
    @State private var weights: [GitHubImport.Weight] = []
    @State private var busy: String?
    @State private var error = ""
    @State private var headers: [String: [GitHubImport.TensorInfo]] = [:]

    private func local(_ w: GitHubImport.Weight) -> URL { ProjectStore.dir(project).appendingPathComponent("models/" + w.path.replacingOccurrences(of: "/", with: "_")) }

    var body: some View {
        List {
            Section(footer: Text("Files are stored and shown only. PocketTrainer never runs them. Limit: 50 MB per file.")) {
                if weights.isEmpty { Text("No model or data files were listed for this project.").foregroundColor(.secondary) }
                ForEach(weights) { w in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(w.path).font(.system(size: 12, design: .monospaced))
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(w.size), countStyle: .file)).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            if FileManager.default.fileExists(atPath: local(w).path) { Label("Downloaded", systemImage: "checkmark.circle").font(.caption).foregroundColor(.green) }
                            else if w.size > GitHubImport.maxWeight { Text("larger than 50 MB").font(.caption).foregroundColor(.secondary) }
                            else if busy == w.id { ProgressView() }
                            else { Button("Download") { download(w) }.buttonStyle(.bordered).font(.caption) }
                        }
                        if let h = headers[w.id] {
                            Text(tr("%ld tensors", h.count)).font(.caption.bold())
                            ForEach(h.prefix(12), id: \.name) { t in Text("\(t.name)  \(t.dtype)  \(t.shape.map(String.init).joined(separator: "×"))").font(.system(size: 10, design: .monospaced)) }
                        }
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.footnote).foregroundColor(.red) }
        }
        .navigationTitle("Model & data files").navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private func load() {
        guard let d = try? Data(contentsOf: ProjectStore.dir(project).appendingPathComponent(".pt_import.json")),
              let rec = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        weights = (rec["weights"] as? [[String: Any]] ?? []).compactMap { w in
            guard let p = w["path"] as? String, let u = w["url"] as? String else { return nil }
            return GitHubImport.Weight(path: p, size: w["size"] as? Int ?? 0, url: u) }
        for w in weights where w.path.hasSuffix(".safetensors") && FileManager.default.fileExists(atPath: local(w).path) { headers[w.id] = GitHubImport.safetensorsHeader(local(w)) }
    }

    private func download(_ w: GitHubImport.Weight) {
        busy = w.id; error = ""
        Task {
            do { let u = try await GitHubImport.downloadWeight(w, project: project); if w.path.hasSuffix(".safetensors") { headers[w.id] = GitHubImport.safetensorsHeader(u) } }
            catch let e { error = e.localizedDescription }
            busy = nil
        }
    }
}

/// 表格数据集：预览、选标签列和特征列、设为训练数据
struct TabularView: View {
    let project: String
    @State private var files: [String] = []
    @State private var file = ""
    @State private var table: TableData?
    @State private var label = 0
    @State private var feats: Set<String> = []
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        List {
            Section(footer: Text("Number columns become features. Text columns are not supported. The label needs 2 to 10 different values. Small tables are repeated to fill training batches.")) {
                Picker("File", selection: $file) { ForEach(files, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) } }
                if busy { ProgressView() }
            }
            if let t = table {
                Section("Dataset preview") {
                    Text(tr("%ld rows · %ld columns", t.rows.count, t.columns.count)).font(.caption).foregroundColor(.secondary)
                    ForEach(Array(t.rows.prefix(4).enumerated()), id: \.offset) { _, r in Text(r.joined(separator: " | ")).font(.system(size: 10, design: .monospaced)).lineLimit(1) }
                }
                Section("Label column") {
                    Picker("Label column", selection: $label) { ForEach(Array(t.columns.enumerated()), id: \.offset) { Text($1).tag($0) } }
                    Text(tr("%ld different values", t.distinct(label))).font(.caption).foregroundColor(.secondary)
                }
                Section("Feature columns") {
                    ForEach(Array(t.columns.enumerated()), id: \.offset) { i, c in
                        if i != label {
                            Toggle(isOn: Binding(get: { feats.contains(c) }, set: { if $0 { feats.insert(c) } else { feats.remove(c) } })) {
                                VStack(alignment: .leading) { Text(c); Text(t.numeric[i] ? "number" : "text — not supported").font(.caption2).foregroundColor(.secondary) }
                            }.disabled(!t.numeric[i])
                        }
                    }
                }
                Section { Button("Use for training") { use(t) }.disabled(feats.isEmpty) }
            }
            if !message.isEmpty { Text(message).font(.footnote).foregroundColor(.secondary) }
        }
        .tint(.teal)
        .navigationTitle("Dataset").navigationBarTitleDisplayMode(.inline)
        .onAppear { files = TabularTools.candidates(project: project); file = TabularTools.config(project: project)?.file ?? files.first ?? "" }
        .onChange(of: file) { _ in open() }
    }

    /// 没下载的表格先下载（≤ 5 MB），再读
    private func open() {
        table = nil; message = ""
        guard !file.isEmpty else { return }
        busy = true
        Task {
            do {
                var rel = file
                if !FileManager.default.fileExists(atPath: ProjectStore.dir(project).appendingPathComponent(file).path) {
                    guard let d = try? Data(contentsOf: ProjectStore.dir(project).appendingPathComponent(".pt_import.json")), let rec = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                          let w = (rec["weights"] as? [[String: Any]])?.first(where: { $0["path"] as? String == file }), let u = w["url"] as? String else { throw TabularTools.Failure(errorDescription: tr("File not found.")) }
                    _ = try await GitHubImport.downloadWeight(GitHubImport.Weight(path: file, size: w["size"] as? Int ?? 0, url: u), project: project, limit: GitHubImport.maxTable)
                    rel = "models/" + file.replacingOccurrences(of: "/", with: "_")
                }
                let t = try TabularTools.load(project: project, rel: rel)
                table = t; label = TabularTools.guessLabel(t)
                feats = Set(t.columns.indices.filter { t.numeric[$0] && $0 != label && !["id", "Id", "ID"].contains(t.columns[$0]) }.map { t.columns[$0] })
                loadedRel = rel
            } catch let e { message = e.localizedDescription }
            busy = false
        }
    }
    @State private var loadedRel = ""

    private func use(_ t: TableData) {
        TabularTools.saveConfig(.init(file: loadedRel, label: t.columns[label], features: t.columns.filter { feats.contains($0) }), project: project)
        // 没有配方就建一个（小网络、多训练几轮）
        if ProjectStore.recipePath(project) == nil {
            try? FileManager.default.createDirectory(at: ProjectStore.dir(project).appendingPathComponent("code"), withIntermediateDirectories: true)
            FileStore.write(project, "code/model.py", "# PocketTrainer recipe for a table dataset\nhidden_units = 32\nlearning_rate = 0.1\nepochs = 200\nseed = 1\n")
        }
        message = tr("Ready: open the project and press Run to train on this table.")
    }
}

/// 环境报告的 Test/Run 之外的 Core ML、表格入口：见 ProjectToolsCard
