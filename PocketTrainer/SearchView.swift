// SearchView.swift —— 「Find projects」：搜索 GitHub 和 Hugging Face（公开接口，不需要 key），选中后「Download & set up」
// 结果会缓存在沙盒里，没网时也能重看。
import SwiftUI

struct SearchHit: Codable, Identifiable {
    var id: String                // GitHub: owner/repo；HF: 模型或数据集 id
    var source: String            // github | hf | hfDataset
    var desc = ""
    var stars: Int?, downloads: Int?, likes: Int?
    var updated: String?, language: String?, license: String?, task: String?
    var url: String { source == "github" ? "https://github.com/\(id)" : (source == "hfDataset" ? "https://huggingface.co/datasets/\(id)" : "https://huggingface.co/\(id)") }
}

enum SearchAPI {
    private static func enc(_ q: String) -> String { q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "+", with: "%2B") ?? q }

    static func search(source: String, query: String) async throws -> [SearchHit] {
        switch source {
        case "github":
            let j = try await GitHubImport.json("https://api.github.com/search/repositories?q=\(enc(query))+language:python&sort=stars&per_page=20")
            return ((j as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap { it in
                guard let id = it["full_name"] as? String else { return nil }
                return SearchHit(id: id, source: "github", desc: it["description"] as? String ?? "", stars: it["stargazers_count"] as? Int,
                                 updated: (it["updated_at"] as? String).map { String($0.prefix(10)) }, language: it["language"] as? String,
                                 license: ((it["license"] as? [String: Any])?["spdx_id"] as? String).flatMap { $0 == "NOASSERTION" ? nil : $0 })
            }
        default:
            let kind = source == "hfDataset" ? "datasets" : "models"
            let j = try await GitHubImport.json("https://huggingface.co/api/\(kind)?search=\(enc(query))&sort=downloads&direction=-1&limit=20")
            return (j as? [[String: Any]] ?? []).compactMap { it in
                guard let id = (it["id"] as? String) ?? (it["modelId"] as? String) else { return nil }
                let tags = it["tags"] as? [String] ?? []
                return SearchHit(id: id, source: source, desc: it["description"] as? String ?? "", downloads: it["downloads"] as? Int, likes: it["likes"] as? Int,
                                 updated: (it["lastModified"] as? String).map { String($0.prefix(10)) },
                                 license: tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst(8)) }, task: it["pipeline_tag"] as? String)
            }
        }
    }

    // ---- 缓存
    private static func cacheURL(_ source: String, _ q: String) -> URL {
        let dir = Store.docs.appendingPathComponent("search_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String("\(source)_\(q.lowercased().filter { $0.isLetter || $0.isNumber })".prefix(80)) + ".json")
    }
    static func save(_ hits: [SearchHit], source: String, query: String) { try? JSONEncoder().encode(hits).write(to: cacheURL(source, query)) }
    static func cached(source: String, query: String) -> [SearchHit]? {
        (try? Data(contentsOf: cacheURL(source, query))).flatMap { try? JSONDecoder().decode([SearchHit].self, from: $0) }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var results: [SearchHit] = []
    @Published var busy = false
    @Published var message = ""
    @Published var fromCache = false

    func run(source: String, query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !busy else { return }
        busy = true; message = ""; fromCache = false
        Task {
            do { results = try await SearchAPI.search(source: source, query: q); SearchAPI.save(results, source: source, query: q) }
            catch let e {
                if let c = SearchAPI.cached(source: source, query: q) { results = c; fromCache = true; message = e.localizedDescription }
                else { results = []; message = e.localizedDescription }
            }
            busy = false
        }
    }
}

struct SearchView: View {
    @StateObject private var m = SearchModel()
    @State private var source = 0            // 0 GitHub · 1 Hugging Face
    @State private var hfKind = 0            // 0 Models · 1 Datasets
    @State private var query = ""
    private let chips = ["mnist", "tiny classifier", "micrograd"]
    private var key: String { source == 0 ? "github" : (hfKind == 0 ? "hf" : "hfDataset") }

    var body: some View {
        List {
            Section {
                Picker("Source", selection: $source) { Text("GitHub").tag(0); Text("Hugging Face").tag(1) }.pickerStyle(.segmented)
                if source == 1 { Picker("Kind", selection: $hfKind) { Text("Models").tag(0); Text("Datasets").tag(1) }.pickerStyle(.segmented) }
                HStack {
                    TextField("Search", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).onSubmit { m.run(source: key, query: query) }
                    Button { m.run(source: key, query: query) } label: { Image(systemName: "magnifyingglass") }.disabled(m.busy)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(chips, id: \.self) { c in Button(c) { query = c; m.run(source: key, query: c) }.buttonStyle(.bordered).font(.caption) } }
                }
            }
            if m.busy { HStack { ProgressView(); Text("Searching…") } }
            if m.fromCache { Text("Showing saved results (offline).").font(.footnote).foregroundColor(.orange) }
            if !m.message.isEmpty { Text(m.message).font(.footnote).foregroundColor(.red) }
            ForEach(m.results) { h in
                NavigationLink { RepoDetailView(hit: h) } label: { row(h) }
            }
            Section(footer: Text("Searches only go to api.github.com and huggingface.co, and only when you tap search. Results are saved on this phone.")) { EmptyView() }
        }
        .navigationTitle("Find projects").navigationBarTitleDisplayMode(.inline)
        .onAppear {       // 截图用：--q=词 --source=github|hf|hfDataset 打开就搜
            func arg(_ k: String) -> String? { CommandLine.arguments.first { $0.hasPrefix("--\(k)=") }.map { String($0.dropFirst(k.count + 3)) } }
            if let q = arg("q"), query.isEmpty { query = q; let s = arg("source") ?? "github"; source = s == "github" ? 0 : 1; hfKind = s == "hfDataset" ? 1 : 0; m.run(source: s, query: q) }
        }
        .onChange(of: source) { _ in m.results = []; m.message = "" }
        .onChange(of: hfKind) { _ in m.results = []; m.message = "" }
    }

    private func row(_ h: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(h.id).font(.subheadline.bold())
            if !h.desc.isEmpty { Text(h.desc).font(.caption).foregroundColor(.secondary).lineLimit(2) }
            HStack(spacing: 10) {
                if let s = h.stars { Label("\(s)", systemImage: "star") }
                if let d = h.downloads { Label("\(d)", systemImage: "arrow.down.circle") }
                if let l = h.likes { Label("\(l)", systemImage: "heart") }
                if let l = h.language { Text(l) }
                if let t = h.task { Text(t) }
                if let u = h.updated { Text(u) }
            }.font(.caption2).foregroundColor(.secondary)
            LicenseBadge(spdx: h.license)
        }
    }
}

/// 详情：许可证、README 摘要、文件列表、大小；「Download & set up」
struct RepoDetailView: View {
    let hit: SearchHit
    @EnvironmentObject var router: Router
    @State private var readme = ""
    @State private var files: [String] = []
    @State private var weights: [GitHubImport.Weight] = []
    @State private var sizeKB = 0
    @State private var info = ""
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(hit.id).font(.title3.bold())
                LicenseBadge(spdx: hit.license)
                if !info.isEmpty { Text(info).font(.footnote).foregroundColor(.secondary) }
                Card {
                    Text("README").font(.subheadline.bold())
                    Text(readme.isEmpty ? tr("Loading…") : readme).font(.footnote)
                }
                Card {
                    Text(tr("%ld files", files.count) + " · " + String(format: "%.0f KB", Double(sizeKB))).font(.subheadline.bold())
                    ForEach(files.prefix(30), id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
                    if files.count > 30 { Text("…").foregroundColor(.secondary) }
                    if !weights.isEmpty {
                        Divider()
                        Text(tr("%ld model/data files (listed, not downloaded)", weights.count)).font(.subheadline.bold())
                        ForEach(weights.prefix(12)) { w in Text("\(w.path)  ·  \(ByteCountFormatter.string(fromByteCount: Int64(w.size), countStyle: .file))").font(.system(size: 11, design: .monospaced)) }
                    }
                }
                Button("Download & set up") { LicenseInfo.level(hit.license) == .ok ? go() : (confirm = true) }.buttonStyle(TealButtonStyle())
                Text("Only text files are downloaded and set up. PocketTrainer does not install Python packages or run downloaded code.").font(.caption).foregroundColor(.secondary)
            }.padding(16)
        }
        .background(Color.pageBackground)
        .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
        .alert("Check the license before using or sharing", isPresented: $confirm) {
            Button("Download anyway") { go() }; Button("Cancel", role: .cancel) {}
        } message: { Text(tr("License: %@", hit.license ?? tr("not stated"))) }
        .task { await load() }
    }

    private func go() { router.setupURL = hit.url; router.tab = .environment; router.showAdd = false }

    private func load() async {
        // README：GitHub 从 raw.githubusercontent.com，Hugging Face 从 huggingface.co/<id>/raw/main
        let readmeURL = hit.source == "github" ? "https://raw.githubusercontent.com/\(hit.id)/HEAD/README.md"
            : "https://huggingface.co/\(hit.source == "hfDataset" ? "datasets/" : "")\(hit.id)/raw/main/README.md"
        if let u = URL(string: readmeURL), let d = try? await GitHubImport.get(u), let t = String(data: d, encoding: .utf8) {
            readme = String(t.replacingOccurrences(of: "\n\n\n", with: "\n\n").prefix(900))
        } else { readme = tr("No README found.") }
        do {
            let p = try await GitHubImport.plan(url: hit.url) { _ in }
            files = p.want.map(\.path); weights = p.weights; sizeKB = p.want.reduce(0) { $0 + $1.size } / 1024
        } catch let t as GitHubImport.TooBig { info = t.errorDescription ?? "" }
        catch let e { info = e.localizedDescription }
    }
}
