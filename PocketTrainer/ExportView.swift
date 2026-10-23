// ExportView.swift —— 编辑页里的「Export」卡片：把训练好的模型导出成 Core ML + PyTorch 能读的权重，并在手机上用导出的 Core ML 模型重新预测、与 App 内结果对拍。
// 说明：本文件由 AI（Claude）编写，须在国会 AI 披露里写明。
import SwiftUI
import CoreML

struct ExportCard: View {
    let project: String
    let isPhotoProject: Bool        // 只有照片项目（CIFAR-10 测试集）才能在这里验证
    @State private var busy = false
    @State private var lines: [String] = []
    @State private var files: [URL] = []

    var body: some View {
        Card {
            Text("Export your model").font(.headline)
            Text("Turn the model you just trained into a Core ML file (runs on any iPhone) and a weights file that PyTorch can read. The app then reloads the exported model and checks it on the 2,000 test photos.")
                .font(.footnote).foregroundColor(.secondary)
            Button(busy ? "Exporting…" : "Export to Core ML") { run() }
                .buttonStyle(TealButtonStyle()).disabled(busy || ProjectStore.latestCheckpoint(project) == nil)
            if ProjectStore.latestCheckpoint(project) == nil { Text("Train the model first (Run).").font(.footnote).foregroundColor(.secondary) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in Text(l).font(.system(.footnote, design: .monospaced)) }
            if !files.isEmpty { ShareLink(items: files) { Label("Share the exported files", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(.teal) }
        }
    }

    private func run() {
        busy = true; lines = []; files = []
        let project = project, photo = isPhotoProject
        Task.detached(priority: .userInitiated) {
            var out: [String] = []; var urls: [URL] = []
            do {
                guard let ck = ProjectStore.latestCheckpoint(project), let (w, H, step) = CoreMLExport.loadCheckpoint(ck.url).map({ ($0.weights, $0.hidden, $0.step) }) else { throw NSError(domain: "export", code: 1, userInfo: [NSLocalizedDescriptionKey: "No valid checkpoint"]) }
                let dir = ProjectStore.dir(project).appendingPathComponent("export", isDirectory: true)
                let r = try CoreMLExport.export(w, hidden: H, to: dir, note: "PocketTrainer · \(project) · step \(step)")
                urls = [r.modelURL, r.safetensorsURL, r.metaURL]
                let kb = { (u: URL) in ((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024 }
                out.append("Exported (step \(step), \(H) hidden units):")
                out.append("  model.mlmodel  \(kb(r.modelURL)) KB")
                out.append("  weights.safetensors  \(kb(r.safetensorsURL)) KB")
                if photo {
                    for u in [MLComputeUnits.cpuOnly, .all] {
                        let v = try CoreMLExport.verify(w, hidden: H, modelURL: r.modelURL, data: Dataset.shared, rows: 2000, units: u)
                        out.append(String(format: "Core ML (%@) on %d photos: %.1f%% correct; same answer as the app %d/%d; biggest score difference %.1e",
                                          v.computeUnits, v.rows, v.coreMLAccuracy * 100, v.sameTop1, v.rows, Double(v.maxAbsDiff)))
                    }
                }
            } catch { out.append("Export failed: \(error.localizedDescription)") }
            let o = out, u = urls
            await MainActor.run { lines = o; files = u; busy = false }
        }
    }
}
