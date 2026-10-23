// ImportView.swift —— 「Import from GitHub」界面
import SwiftUI

@MainActor
final class ImportModel: ObservableObject {
    @Published var url = ""
    @Published var busy = false
    @Published var status = ""
    @Published var errorText = ""
    @Published var summary: GitHubImport.Summary?

    static let example = "https://github.com/karpathy/micrograd"      // 公开、MIT 许可证的小项目，用来演示导入

    func start(store: ProjectStore) {
        guard !busy else { return }
        busy = true; errorText = ""; summary = nil; status = ""
        Task {
            do { summary = try await GitHubImport.run(url: url, store: store) { s in Task { @MainActor in self.status = s } } }
            catch let t as GitHubImport.TooBig { errorText = t.errorDescription ?? ""; summary = t.summary }
            catch let e { errorText = e.localizedDescription }
            busy = false
        }
    }

    /// 自动测试：--auto-demo=import --url=<链接>，把数字写进 Documents/import.json
    static func autoDemo(url: String, store: ProjectStore) {
        let m = ImportModel(); m.url = url
        Task {
            var out: [String: Any] = ["url": url]
            let t0 = Date()
            do {
                let s = try await GitHubImport.run(url: url, store: store) { _ in }
                out["files"] = s.files.count; out["bytes"] = s.bytes; out["license"] = s.license ?? "unknown"; out["licenseFetched"] = s.licenseText != nil
                out["skipped"] = s.skipped.map { "\($0.path) (\($0.reason))" }; out["project"] = s.project
                out["recipeFound"] = ProjectStore.recipePath(s.project) != nil
                out["mapCandidates"] = RecipeMap.scan(s.project).map { "\($0.name)=\($0.value)→\($0.key)" }
            } catch { out["error"] = error.localizedDescription }
            out["seconds"] = -t0.timeIntervalSinceNow
            try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: Store.docs.appendingPathComponent("import.json"))
        }
    }
}

struct ImportView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var router: Router
    @StateObject private var m = ImportModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    Text("Paste a GitHub address").font(.subheadline.bold())
                    TextField("https://github.com/<owner>/<repo>", text: $m.url).font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                    Text("Also works with a link to a sub-folder (…/tree/main/folder) or a single file (…/blob/main/file.py).").font(.caption).foregroundColor(.secondary)
                    Label("Check the project's license before using or sharing it.", systemImage: "info.circle").font(.footnote).foregroundColor(.orange)
                    Button("Import") { m.start(store: store) }.buttonStyle(TealButtonStyle()).disabled(m.busy || m.url.isEmpty)
                    Button("Try an example") { m.url = ImportModel.example; m.start(store: store) }.buttonStyle(.bordered).tint(.teal).disabled(m.busy)
                    Text("PocketTrainer goes online only while importing. Only text files from github.com are downloaded; they are shown and edited, never run.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if m.busy { HStack { ProgressView(); Text(m.status).font(.footnote) } }
                if !m.errorText.isEmpty { Text(m.errorText).font(.footnote).foregroundColor(.red) }
                if let s = m.summary { resultCard(s) }
            }.padding(16)
        }
        .background(Color.pageBackground)
        .navigationTitle("Import from GitHub").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func resultCard(_ s: GitHubImport.Summary) -> some View {
        if !s.tooBig.isEmpty {
            Card {
                Text("Choose a sub-folder").font(.subheadline.bold())
                ForEach(s.tooBig.prefix(8), id: \.dir) { d in
                    Button { m.url = subdirURL(s.source, d.dir) } label: {
                        Text("\(d.dir)  ·  \(tr("%ld files", d.count))").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else if !s.project.isEmpty {
            Card {
                Text("Imported").font(.headline)
                Text(tr("%ld files · %.1f KB · %.1f s", s.files.count, Double(s.bytes) / 1024, s.seconds)).font(.subheadline)
                Text(tr("License: %@", s.license ?? tr("not stated"))).font(.subheadline.bold())
                if let t = s.licenseText { Text(String(t.prefix(600))).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary) }
                else { Text("No LICENSE file was found. Ask the author before using or sharing it.").font(.footnote).foregroundColor(.orange) }
                Label("Check the project's license before using or sharing it.", systemImage: "info.circle").font(.footnote).foregroundColor(.orange)
                if !s.skipped.isEmpty {
                    DisclosureGroup(tr("Skipped %ld files", s.skipped.count)) {
                        ForEach(Array(s.skipped.prefix(40).enumerated()), id: \.offset) { _, k in Text("\(k.path) — \(tr(k.reason))").font(.system(size: 11, design: .monospaced)) }
                    }.font(.footnote)
                }
                Button("Open project") { store.touch(s.project); router.tab = .projects; router.path = [.editor(s.project)]; dismiss() }.buttonStyle(TealButtonStyle())
            }
        }
    }

    /// 同一个仓库、换成某个子目录的链接（GitHub 或 Hugging Face）
    private func subdirURL(_ source: String, _ dir: String) -> String {
        guard let r = try? GitHubImport.parse(source) else { return source }
        switch r.source {
        case .github: return "https://github.com/\(r.owner)/\(r.repo)/tree/\(r.branch ?? "HEAD")/\(dir)"
        case .hf: return "https://huggingface.co/\(r.hfID)/tree/main/\(dir)"
        case .hfDataset: return "https://huggingface.co/datasets/\(r.hfID)/tree/main/\(dir)"
        }
    }
}
