// CoreMLView.swift —— 项目里的「Core ML model」页：下载 → 编译 → 选照片运行 → Top-5 + GPU/CPU 核对
import SwiftUI
import PhotosUI

struct CoreMLView: View {
    let project: String
    @State private var cands: [CoreMLCandidate] = []
    @State private var working: String?             // 正在处理的模型名
    @State private var frac = 0.0
    @State private var status = ""
    @State private var error = ""
    @State private var ready: URL?
    @State private var info: [String] = []
    @State private var task: Task<Void, Never>?
    @State private var pick: PhotosPickerItem?
    @State private var result: ResultInfo?
    @State private var usedAsExtractor = false

    struct ResultInfo { var top: [(label: String, p: Double)]; var verdict: String; var ok: Bool; var detail: String }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Core ML models are data (weights and a graph) run by the system's Core ML engine. PocketTrainer compiles them on this phone and never runs downloaded code.").font(.footnote).foregroundColor(.secondary)
                if cands.isEmpty { Text("No runnable Core ML model found").foregroundColor(.secondary) }
                if let url = ready {
                    Card {
                        Label("Model ready", systemImage: "checkmark.seal.fill").foregroundColor(.teal).font(.subheadline.bold())
                        ForEach(info, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
                        HStack {
                            PhotosPicker(selection: $pick, matching: .images) { Label("Choose photo", systemImage: "photo") }.buttonStyle(.bordered)
                            Button { run(url, CoreMLTools.sampleImage()) } label: { Label("Use sample image", systemImage: "square.fill.on.circle.fill") }.buttonStyle(.bordered)
                        }
                        Text("Photos stay on this phone.").font(.caption2).foregroundColor(.secondary)
                    }
                    if let r = result { resultCard(r) }
                }
                if !error.isEmpty { Text(error).font(.footnote).foregroundColor(.red) }
                ForEach(cands) { c in
                    Card {
                        Text(c.name).font(.subheadline.bold())
                        Text(ByteCountFormatter.string(fromByteCount: Int64(c.size), countStyle: .file) + (c.size > GitHubImport.maxCoreML ? " — " + tr("larger than 100 MB, not downloaded") : "")).font(.caption).foregroundColor(.secondary)
                        if working == c.id {
                            ProgressView(value: frac); Text(status).font(.caption)
                            Button("Cancel", role: .cancel) { task?.cancel() }.buttonStyle(.bordered)
                        } else {
                            Button(tr("Download & compile (%@)", ByteCountFormatter.string(fromByteCount: Int64(c.size), countStyle: .file))) { prepare(c) }
                                .buttonStyle(TealButtonStyle()).disabled(working != nil || c.size > GitHubImport.maxCoreML)
                        }
                    }
                }
            }.padding(16)
        }
        .background(Color.pageBackground)
        .navigationTitle("Core ML model").navigationBarTitleDisplayMode(.inline)
        .onAppear { cands = CoreMLTools.candidates(project: project); restoreReady() }
        .onChange(of: pick) { item in
            guard let item, let url = ready else { return }
            Task { if let d = try? await item.loadTransferable(type: Data.self), let cg = UIImage(data: d)?.cgImage { run(url, cg) } }
        }
    }

    private func resultCard(_ r: ResultInfo) -> some View {
        Card {
            Text("Top 5").font(.subheadline.bold())
            ForEach(Array(r.top.enumerated()), id: \.offset) { _, t in
                HStack { Text(t.label).font(.subheadline); Spacer(); Text(String(format: "%.1f%%", t.p * 100)).font(.subheadline.monospacedDigit()) }
            }
            Text(r.verdict).font(.subheadline.bold()).foregroundColor(r.ok ? .green : .orange)
            Text(r.detail).font(.caption).foregroundColor(.secondary)
            if r.top.first?.label.hasPrefix("#") == true, let url = ready {       // 输出是向量（没有标签）：可以当特征提取器
                Button(usedAsExtractor ? tr("Done") : tr("Use this model as the feature extractor")) {
                    UserDefaults.standard.set(String(url.path.dropFirst(Store.docs.path.count + 1)), forKey: FeatureExtractor.customKey); usedAsExtractor = true
                }.buttonStyle(.bordered).tint(.teal).disabled(usedAsExtractor)
                Text("Teach it your own photos will use this model for its features. The classifier is rebuilt for the new feature size.").font(.caption2).foregroundColor(.secondary)
            }
            Text("Verified means the GPU and CPU answers match (cosine similarity ≥ 0.999 and largest difference ≤ 0.02). It double-checks one run; it does not repair anything.").font(.caption2).foregroundColor(.secondary)
        }
    }

    private func restoreReady() {
        for c in cands { let u = CoreMLTools.compiledURL(project: project, name: (c.name as NSString).deletingPathExtension)
            if FileManager.default.fileExists(atPath: u.path) { ready = u; info = CoreMLTools.describe(u); break } }
        if CommandLine.arguments.contains("--coreml-run"), let u = ready { run(u, CoreMLTools.sampleImage()) }      // 截图用
    }

    private func prepare(_ c: CoreMLCandidate) {
        working = c.id; error = ""; frac = 0; result = nil
        task = Task {
            do {
                let u = try await CoreMLTools.prepare(c, project: project) { f, s in Task { @MainActor in frac = f; status = s } }
                ready = u; info = CoreMLTools.describe(u)
            } catch is CancellationError { error = tr("Cancelled.") }
            catch let e { error = e.localizedDescription }
            working = nil
        }
    }

    /// 同一张图在 GPU 和 CPU 上各跑一次，对比输出
    private func run(_ url: URL, _ image: CGImage) {
        error = ""
        do {
            let g = try CoreMLTools.predict(url, image: image, units: .cpuAndGPU)
            let c = try CoreMLTools.predict(url, image: image, units: .cpuOnly)
            let cmp = CoreMLTools.compare(g.vector, c.vector)
            result = ResultInfo(top: g.top, verdict: cmp.ok ? tr("✓ Verified: GPU result matches CPU") : tr("⚠ GPU result differs from CPU — possible silent error"), ok: cmp.ok,
                                detail: tr("cosine similarity %.6f · largest difference %.5f · GPU %.0f ms · CPU %.0f ms", cmp.cos, cmp.maxDiff, g.seconds * 1000, c.seconds * 1000))
        } catch let e { error = e.localizedDescription }
    }
}
