// DataViews.swift —— 「训练」页里的数据卡片 + 选数据的弹窗（从 Hugging Face 开放数据网站挑一份小数据集，下载到项目的 data/ 里）
// 说明：本文件由 AI（Claude）编写，须在国会 AI 披露里写明。
import SwiftUI

/// 灰度 28×28（或 RGB 32×32）的字节 → 小图
enum PixelImage {
    static func gray(_ px: [UInt8], side: Int = 28) -> UIImage? {
        guard px.count == side * side, let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
    static func rgb(_ px: [UInt8], side: Int = 32) -> UIImage? {
        guard px.count == side * side * 3, let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: side * 3, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 一张像素小图（放大时不模糊，看得清像素）
struct PixelView: View {
    let image: UIImage?
    var size: CGFloat = 56
    var body: some View {
        Group {
            if let image { Image(uiImage: image).interpolation(.none).resizable() } else { Color.secondary.opacity(0.2) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 训练页里的「Data」卡片：现在用哪份数据、从哪来、许可证，点「Choose data」换
struct DataCard: View {
    let project: String, kind: String
    var willChange: () -> Void = {}
    var changed: () -> Void = {}
    @State private var showPicker = false
    @State private var version = 0
    static var autoOpened = false

    var body: some View {
        let src = ProjectData.source(project)
        Card {
            HStack {
                Label("Data", systemImage: "tray.full").font(.headline)
                Spacer()
                Button(src == nil && kind == "generator" ? tr("Choose data") : tr("Change")) { willChange(); showPicker = true }.font(.subheadline.weight(.semibold)).tint(.teal)
            }
            if let s = src {
                Text(tr(s.title)).font(.subheadline.weight(.semibold))
                Text(s.kind == "images" ? tr("%ld pictures · %ld classes · license %@", s.count, s.classes.count, s.license) : tr("%ld rows · %ld classes · label “%@” · license %@", s.count, s.classes.count, s.label, s.license))
                    .font(.caption).foregroundColor(.secondary)
                if s.kind == "images", let im = ProjectData.images(project) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) { ForEach(0..<min(12, im.count), id: \.self) { i in PixelView(image: PixelImage.gray(Array(im.pixels[(i * 784)..<((i + 1) * 784)])), size: 34) } }
                    }
                }
                if let u = URL(string: s.url) { Link(destination: u) { Label(tr("From %@", "huggingface.co/datasets/" + s.repo), systemImage: "link").font(.caption) } }
                Text(tr("Stored in this project: %@", s.file ?? "data/")).font(.caption2).foregroundColor(.secondary)
            } else if kind == "generator" {
                Text("No pictures yet. Choose a picture dataset to train on — the app downloads it from Hugging Face, an open website for AI datasets.").font(.footnote).foregroundColor(.secondary)
            } else if let c = TabularTools.config(project: project) {
                Text(tr("Table: %@ · label “%@”", c.file, c.label)).font(.subheadline)
            } else {
                Text("Built-in: CIFAR-10 photos").font(.subheadline.weight(.semibold))
                Text("5,000 training photos and 2,000 test photos (10 classes), already turned into 2,048 numbers each on this phone's ResNet50.").font(.caption).foregroundColor(.secondary)
            }
        }
        .id(version)
        .onAppear { if CommandLine.arguments.contains("--data-picker") && !DataCard.autoOpened { DataCard.autoOpened = true; showPicker = true } }   // 截图用
        .sheet(isPresented: $showPicker, onDismiss: { version += 1; changed() }) { DataPickerSheet(project: project, kind: kind) }
    }
}

/// 选数据：列出几份精选的小数据集（Hugging Face 上的开放数据），实时显示网站上的下载量和许可证；点了就下载进项目
struct DataPickerSheet: View {
    let project: String, kind: String
    @Environment(\.dismiss) private var dismiss
    @State private var live: [String: LiveInfo] = [:]
    @State private var busy: String?
    @State private var progress = 0.0
    @State private var status = ""
    @State private var error = ""

    private var choices: [OpenDataset] { OpenDataset.catalog.filter { kind != "generator" || $0.kind == .images } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(kind == "generator" ? "Pick the pictures your generator learns to draw. They are downloaded from Hugging Face (huggingface.co), an open website for AI datasets, and saved in this project's data folder." : "Pick the data your model learns from. It is downloaded from Hugging Face (huggingface.co), an open website for AI datasets, and saved in this project's data folder.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                if kind == "cifar" {
                    Section {
                        Button { ProjectData.useBuiltin(project); dismiss() } label: {
                            row(title: tr("Built-in: CIFAR-10 photos"), blurb: tr("Already on this phone. 10 kinds of photos (planes, cars, animals…)."), badge: tr("Built-in"), info: nil, current: ProjectData.source(project) == nil && TabularTools.config(project: project) == nil)
                        }.disabled(busy != nil)
                    }
                }
                Section("Hugging Face") {
                    ForEach(choices) { ds in
                        Button { Task { await pick(ds) } } label: {
                            row(title: tr(ds.title), blurb: tr(ds.blurb), badge: ds.kind == .images ? tr("%ld pictures", ds.count) : tr("Table"), info: live[ds.id], current: ProjectData.source(project)?.id == ds.id, license: ds.license, repo: ds.repo)
                        }.disabled(busy != nil)
                        if busy == ds.id {
                            VStack(alignment: .leading, spacing: 4) { ProgressView(value: progress); Text(status).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
                if !error.isEmpty { Text(error).font(.footnote).foregroundColor(.red) }
            }
            .navigationTitle("Choose data").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.disabled(busy != nil) }
            .task {
                await withTaskGroup(of: (String, LiveInfo).self) { g in
                    for ds in choices { g.addTask { (ds.id, await ProjectData.liveInfo(ds)) } }
                    for await (id, info) in g { live[id] = info }
                }
            }
        }
        .interactiveDismissDisabled(busy != nil)
    }

    private func row(title: String, blurb: String, badge: String, info: LiveInfo?, current: Bool, license: String? = nil, repo: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: current ? "checkmark.circle.fill" : "circle").foregroundColor(current ? .teal : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(title).font(.headline).foregroundColor(.primary); Spacer(); Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.teal.opacity(0.15))).foregroundColor(.teal) }
                Text(blurb).font(.caption).foregroundColor(.secondary)
                if let repo {
                    let lic = info?.license.map { $0.uppercased() } ?? license ?? ""
                    let dl = info?.downloads.map { tr("%ld downloads last month", $0) }
                    Text([repo, tr("License %@", lic), dl].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundColor(.secondary)
                }
            }
        }.padding(.vertical, 2)
    }

    private func pick(_ ds: OpenDataset) async {
        busy = ds.id; error = ""; progress = 0; status = tr("Connecting to Hugging Face …")
        do {
            let src = try await ProjectData.download(ds, project: project) { done, total, text in
                Task { @MainActor in progress = total > 0 ? Double(done) / Double(total) : 0; status = text }
            }
            if kind != "generator" { ProjectData.applySuggested(ds, trainRows: src.count - max(5, src.count / 5), project: project) }
            busy = nil; dismiss()
        } catch let e {
            busy = nil; error = e.localizedDescription
        }
    }
}
