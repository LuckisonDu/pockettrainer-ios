// ResultView.swift —— 项目的「结果」页：拿训练好的模型，在这台手机上把没参与训练的测试数据一个个跑一遍：输入 → 模型 → 输出。
// 分类项目：照片 / 手写数字 / 表格行 → 预测的类别 + 有多确定 + 对不对；手写数字还能自己画一个让它认。
// 生成器项目：选一个类别 → 模型画出新图；风格地图；「编码 → 解码」复制一张图。全部在手机上算，不联网。
// 说明：本文件由 AI（Claude）编写，须在国会 AI 披露里写明。
import SwiftUI

struct ResultView: View {
    let project: String, kind: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if kind == "generator" { GeneratorResult(project: project) } else { ClassifierResult(project: project) }
            }.padding(14)
        }
        .background(Color.pageBackground)
    }
}

/// 「输入 → 模型 → 输出」三栏的表头
struct FlowHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Input").frame(width: 76, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption2)
            Label("Model", systemImage: "cpu").labelStyle(.titleAndIcon)
            Image(systemName: "arrow.right").font(.caption2)
            Text("Output")
            Spacer()
        }.font(.caption.weight(.semibold)).foregroundColor(.secondary)
    }
}

/// 中间那一格：模型（在这台手机上）
struct ModelChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
            Image(systemName: "cpu").font(.caption).foregroundColor(.teal).padding(5).background(Circle().fill(Color.teal.opacity(0.12)))
            Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
        }
    }
}

// MARK: - 分类项目

struct ClassifierResult: View {
    let project: String
    @EnvironmentObject var trainer: Trainer

    enum Input { case photo(UIImage?), values([(String, String)]) }
    struct Item: Identifiable { let id: Int; let input: Input; let pred: Int; let conf: Double; let truth: Int }
    enum Status { case loading, noModel, stale, ready, failed(String) }

    @State private var status = Status.loading
    @State private var items: [Item] = []
    @State private var classes: [String] = []
    @State private var accuracy = 0.0
    @State private var testCount = 0
    @State private var ms = 0.0
    @State private var step = 0
    @State private var dataTitle = ""
    @State private var filter: Int? = nil
    @State private var shown = 20
    @State private var weights: (Weights, Int)?
    @State private var drawable = false

    var body: some View {
        Group {
            switch status {
            case .loading: ProgressView().frame(maxWidth: .infinity).padding(40)
            case .noModel: emptyCard(tr("No trained model yet."), tr("Go to the Training tab and press Run. Then come back here to see what the model does with pictures it has never seen."))
            case .stale: emptyCard(tr("The data changed after the last training."), tr("This project now uses different data. Press Run in the Training tab to train on it, then come back."))
            case .failed(let m): emptyCard(tr("Could not show results."), m)
            case .ready: ready
            }
        }
        .task(id: trainer.running) { if !trainer.running { await load() } }
    }

    private func emptyCard(_ title: String, _ text: String) -> some View {
        Card { Label(title, systemImage: "sparkles.rectangle.stack").font(.headline); Text(text).font(.footnote).foregroundColor(.secondary) }
    }

    private var visible: [Item] { items.filter { filter == nil || $0.truth == filter } }

    @ViewBuilder private var ready: some View {
        Card {
            Text("How the model does").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.1f%%", accuracy * 100)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundColor(.teal)
                Text(tr("correct on %ld test items it never saw while training", testCount)).font(.footnote).foregroundColor(.secondary)
            }
            Text(tr("Data: %@ · model from step %ld", dataTitle, step)).font(.caption).foregroundColor(.secondary)
            Label(tr("The model ran on this iPhone: %ld inputs in %.1f ms. Nothing was sent anywhere.", items.count, ms), systemImage: "iphone").font(.caption).foregroundColor(.secondary)
        }
        Card {
            Text("Test examples").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(tr("All"), filter == nil) { filter = nil }
                    ForEach(classes.indices, id: \.self) { c in chip(tr(classes[c]), filter == c) { filter = c } }
                }
            }
            FlowHeader()
            ForEach(visible.prefix(shown)) { it in row(it); Divider() }
            if visible.count > shown { Button(tr("Show more")) { shown += 20 }.frame(maxWidth: .infinity).tint(.teal) }
        }
        if drawable, let w = weights { DrawDigitCard(weights: w.0, hidden: w.1, classes: classes) }
    }

    private func chip(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(on ? Color.teal : Color.teal.opacity(0.1))).foregroundColor(on ? .white : .teal)
        }
    }

    private func row(_ it: Item) -> some View {
        let ok = it.pred == it.truth
        return HStack(spacing: 8) {
            switch it.input {
            case .photo(let img): PixelView(image: img, size: 64).frame(width: 76, alignment: .leading)
            case .values(let kv):
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(kv.prefix(4).indices, id: \.self) { i in Text("\(kv[i].0): \(kv[i].1)").lineLimit(1).minimumScaleFactor(0.7) }
                    if kv.count > 4 { Text(tr("+%ld more", kv.count - 4)) }
                }.font(.system(size: 9.5, design: .monospaced)).foregroundColor(.secondary).frame(width: 128, alignment: .leading)
            }
            ModelChip()
            VStack(alignment: .leading, spacing: 3) {
                Text(tr(classes[safe: it.pred] ?? "?")).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                ProgressView(value: it.conf).tint(ok ? .teal : .orange).frame(maxWidth: 90)
                Text(tr("%ld%% sure", Int((it.conf * 100).rounded()))).font(.caption2).foregroundColor(.secondary)
                if !ok { Text(tr("Answer: %@", tr(classes[safe: it.truth] ?? "?"))).font(.caption2).foregroundColor(.orange) }
            }
            Spacer(minLength: 0)
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(ok ? .green : .red).font(.title3)
        }
    }

    // MARK: 算结果（后台线程）

    private func load() async {
        let project = project
        let r: Result<Loaded, Error>? = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, Error>? in
            guard let ck = ProjectStore.latestCheckpoint(project), let c = CoreMLExport.loadCheckpoint(ck.url) else { return nil }
            do { return .success(try ClassifierResult.compute(project: project, weights: c.weights, hidden: c.hidden, step: c.step)) } catch { return .failure(error) }
        }.value
        guard let r else { status = .noModel; return }
        if ProjectData.trainedOn(project) != ProjectData.dataKey(project) { status = .stale; return }
        switch r {
        case .failure(let e): status = .failed(e.localizedDescription)
        case .success(let l):
            items = l.items; classes = l.classes; accuracy = l.accuracy; testCount = l.testCount; ms = l.ms; step = l.step; dataTitle = l.dataTitle
            weights = (l.weights, l.hidden); drawable = ProjectData.source(project)?.id == "mnist"; status = .ready
        }
    }

    struct Loaded { let items: [Item]; let classes: [String]; let accuracy: Double; let testCount: Int; let ms: Double; let step: Int; let dataTitle: String; let weights: Weights; let hidden: Int }

    /// 把测试数据跑一遍模型；返回每一条的输入、预测、确定程度、正确答案
    nonisolated static func compute(project: String, weights w: Weights, hidden: Int, step: Int) throws -> Loaded {
        let cpu = CPUNet(H: hidden, lr: 0), D = featureDim
        var rows: [(input: Input, x: ArraySlice<Float>, truth: Int)] = []
        let data: Dataset, classes: [String], title: String
        if let im = ProjectData.images(project) {
            let (ds, cl) = try ProjectData.imageDataset(project: project); data = ds; classes = cl
            title = tr(ProjectData.source(project)?.title ?? "")
            let test = ProjectData.split(im.count).test
            for (i, r) in test.prefix(120).enumerated() {
                rows.append((.photo(PixelImage.gray(Array(im.pixels[(r * 784)..<((r + 1) * 784)]))), ds.testX[(i * D)..<((i + 1) * D)], Int(ds.testY[i])))
            }
        } else if let cfg = TabularTools.config(project: project) {
            let (ds, cl) = try TabularTools.buildDataset(project: project); data = ds; classes = cl.map { ProjectData.display($0, project: project) }
            let t = try TabularTools.load(project: project, rel: cfg.file)
            title = ProjectData.source(project).map { tr($0.title) } ?? (cfg.file as NSString).lastPathComponent
            let fi = cfg.features.compactMap { t.columns.firstIndex(of: $0) }.filter { t.numeric[$0] }
            for (i, r) in ProjectData.split(t.rows.count).test.prefix(120).enumerated() {
                rows.append((.values(fi.map { (t.columns[$0], t.rows[r][$0]) }), ds.testX[(i * D)..<((i + 1) * D)], Int(ds.testY[i])))
            }
        } else {
            data = Dataset.shared; classes = classNames; title = tr("Built-in: CIFAR-10 photos")
            // 内置测试集按类别排：第 c 类的第 i 张（测试集顺序）= 第 c*200+i 行；App 里带了每类前 8 张的 32×32 小图
            let thumbs = Bundle.main.url(forResource: "cifar_thumbs", withExtension: "u8").flatMap { try? Data(contentsOf: $0) }.map { [UInt8]($0) } ?? []
            for i in 0..<8 { for c in 0..<numClasses {
                let r = c * 200 + i, k = c * 8 + i
                let img = thumbs.count >= (k + 1) * 3072 ? PixelImage.rgb(Array(thumbs[(k * 3072)..<((k + 1) * 3072)])) : nil
                rows.append((.photo(img), data.testX[(r * D)..<((r + 1) * D)], Int(data.testY[r])))
            } }
        }
        // 一次把这些输入全送进模型
        let t0 = Date()
        let z = cpu.logits(w, rows.flatMap { $0.x }, rows.count)
        let ms = -t0.timeIntervalSinceNow * 1000
        let C = numClasses, nc = classes.count
        var items: [Item] = []
        for (i, r) in rows.enumerated() {
            let zr = Array(z[(i * C)..<(i * C + nc)]), m = zr.max() ?? 0
            let e = zr.map { Double(expf($0 - m)) }, s = e.reduce(0, +)
            let p = e.firstIndex(of: e.max() ?? 0) ?? 0
            items.append(Item(id: i, input: r.input, pred: p, conf: e[p] / s, truth: r.truth))
        }
        return Loaded(items: items, classes: classes, accuracy: cpu.accuracy(w, data), testCount: data.testCount, ms: ms, step: step, dataTitle: title, weights: w, hidden: hidden)
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

/// 自己画一个数字，让模型认（只在手写数字数据集时出现）
struct DrawDigitCard: View {
    let weights: Weights, hidden: Int, classes: [String]
    @State private var strokes: [[CGPoint]] = []
    @State private var answer: (Int, Double)?
    @State private var seen: UIImage?
    private let side: CGFloat = 200

    var body: some View {
        Card {
            Text("Draw a digit").font(.headline)
            Text("Draw any digit with your finger. The model reads it on this phone and tells you what it sees.").font(.caption).foregroundColor(.secondary)
            HStack(alignment: .center, spacing: 10) {
                Canvas { ctx, _ in
                    for s in strokes {
                        var p = Path(); p.addLines(s)
                        ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(width: side, height: side).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 10))
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    if v.translation == .zero || strokes.isEmpty { strokes.append([v.location]) } else { strokes[strokes.count - 1].append(v.location) }
                }.onEnded { _ in recognize() })
                VStack(spacing: 6) {
                    ModelChip()
                    if let seen { PixelView(image: seen, size: 40); Text("what it sees").font(.caption2).foregroundColor(.secondary) }
                    if let (p, c) = answer {
                        Text(classes[safe: p] ?? "?").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundColor(.teal)
                        Text(tr("%ld%% sure", Int((c * 100).rounded()))).font(.caption2).foregroundColor(.secondary)
                    }
                }.frame(maxWidth: .infinity)
            }
            Button("Clear") { strokes = []; answer = nil; seen = nil }.font(.subheadline).tint(.teal)
        }
    }

    /// 画的笔画 → 和 MNIST 一样的 28×28（数字放在中间 20×20 的框里）→ 模型
    private func recognize() {
        let pts = strokes.flatMap { $0 }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return }
        let n = 28, pad: CGFloat = 8
        let w = max(maxX - minX, maxY - minY) + 2 * pad, cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        var px = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        let scale = 20 / w
        ctx.translateBy(x: 0, y: CGFloat(n)); ctx.scaleBy(x: 1, y: -1)              // 和屏幕一样：y 向下
        ctx.translateBy(x: 14, y: 14); ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -cx, y: -cy)
        ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setLineWidth(16); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for s in strokes where !s.isEmpty {
            ctx.move(to: s[0]); for p in s.dropFirst() { ctx.addLine(to: p) }
            if s.count == 1 { ctx.addLine(to: s[0]) }
            ctx.strokePath()
        }
        seen = PixelImage.gray(px)
        var x = [Float](repeating: 0, count: featureDim)
        for k in 0..<(n * n) { x[k] = Float(px[k]) / 255 }
        let z = CPUNet(H: hidden, lr: 0).logits(weights, x, 1)
        let zr = Array(z.prefix(classes.count)), m = zr.max() ?? 0
        let e = zr.map { Double(expf($0 - m)) }, s = e.reduce(0, +), p = e.firstIndex(of: e.max() ?? 0) ?? 0
        answer = (p, e[p] / s)
    }
}

// MARK: - 生成器项目

struct GeneratorResult: View {
    let project: String
    @ObservedObject private var gen = GenTrainer.shared
    @State private var model: CVAE?
    @State private var classes: [String] = []
    @State private var label = 7
    @State private var samples: [[UInt8]] = []
    @State private var map: [[UInt8]] = []
    @State private var copies: [([UInt8], [UInt8])] = []
    @State private var ms = 0.0
    @State private var seed: UInt64 = 1
    @State private var stale = false

    var body: some View {
        Group {
            if gen.running && gen.project == project {
                Card { Label("Training…", systemImage: "hourglass").font(.headline); Text("The model is still learning. Watch it in the Training tab; results show here when it finishes.").font(.footnote).foregroundColor(.secondary) }
            } else if model == nil {
                Card { Label("No trained generator yet.", systemImage: "paintbrush.pointed").font(.headline); Text("Go to the Training tab, choose a picture dataset, and press Run. Then come back to see the new pictures it draws.").font(.footnote).foregroundColor(.secondary) }
            } else if stale {
                Card { Label("The data changed after the last training.", systemImage: "exclamationmark.triangle").font(.headline); Text("Press Run in the Training tab to train on the new pictures.").font(.footnote).foregroundColor(.secondary) }
            } else { ready }
        }
        .onAppear { reload() }
        .onChange(of: gen.saved) { _ in if !gen.running { reload() } }
    }

    @ViewBuilder private var ready: some View {
        Card {
            Text("Make new pictures").font(.headline)
            Text("Pick a class. The model starts from 2 random numbers (the “style”) and draws a picture of that class that is not in the training data.").font(.caption).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(classes.indices, id: \.self) { c in
                        Button { label = c; draw() } label: {
                            Text(tr(classes[c])).font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(label == c ? Color.teal : Color.teal.opacity(0.1))).foregroundColor(label == c ? .white : .teal)
                        }
                    }
                }
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    Text(tr(classes[safe: label] ?? "")).font(.headline)
                    Text("+ 2 random numbers").font(.caption2).foregroundColor(.secondary)
                }.frame(width: 84, alignment: .leading)
                ModelChip()
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 4), spacing: 4) {
                    ForEach(samples.indices, id: \.self) { i in PixelView(image: PixelImage.gray(samples[i]), size: 44) }
                }
            }
            HStack {
                Button { seed &+= 1; draw() } label: { Label("Draw again", systemImage: "dice") }.buttonStyle(.bordered).tint(.teal)
                Spacer()
                Text(tr("8 pictures in %.1f ms on this iPhone", ms)).font(.caption2).foregroundColor(.secondary)
            }
        }
        Card {
            Text("Style map").font(.headline)
            Text(tr("The same class “%@”, drawn with different style numbers. Left to right and top to bottom, the two numbers go from −2 to +2.", tr(classes[safe: label] ?? ""))).font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(map.indices, id: \.self) { i in PixelView(image: PixelImage.gray(map[i]), size: 40) }
            }
        }
        Card {
            Text("Copy a picture (encode → decode)").font(.headline)
            Text("A test picture goes in, the model squeezes it into 2 numbers, then draws it back from those 2 numbers.").font(.caption).foregroundColor(.secondary)
            FlowHeader()
            ForEach(copies.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    PixelView(image: PixelImage.gray(copies[i].0), size: 56).frame(width: 76, alignment: .leading)
                    ModelChip()
                    PixelView(image: PixelImage.gray(copies[i].1), size: 56)
                    Spacer()
                }
            }
        }
        if let info = GenTrainer.info(project) {
            Card {
                Text("About this model").font(.headline)
                Text(tr("Trained on this phone: %ld pictures, %ld steps, %.1f s.", info["pictures"] as? Int ?? 0, info["steps"] as? Int ?? 0, info["seconds"] as? Double ?? 0)).font(.caption)
                Text(tr("Size: %ld numbers (%.1f MB). A small conditional VAE: picture + class → 2 numbers → picture.", (model?.params.map(\.count).reduce(0, +)) ?? 0, Double((model?.params.map(\.count).reduce(0, +)) ?? 0) * 4 / 1_048_576)).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func reload() {
        model = GenTrainer.load(project)
        let src = ProjectData.source(project)
        classes = src?.classes ?? (0..<10).map(String.init)
        if label >= classes.count { label = 0 }
        stale = model != nil && ProjectData.trainedOn(project) != ProjectData.dataKey(project)
        guard model != nil, !stale else { return }
        draw()
        if let im = ProjectData.images(project), let m = model {
            let test = Array(ProjectData.split(im.count).test.prefix(6))
            let (x, _) = GenTrainer.batch(im, test)
            let out = m.reconstruct(x, label: test.map { Int(im.labels[$0]) })
            copies = test.indices.map { (Array(im.pixels[(test[$0] * 784)..<((test[$0] + 1) * 784)]), out[$0]) }
        }
    }

    /// 画 8 张新图 + 7×7 风格地图
    private func draw() {
        guard let m = model else { return }
        var g = LCG(seed: seed &* 31 &+ UInt64(label))
        let t0 = Date()
        samples = m.generate(label: label, count: 8, rng: &g)
        ms = -t0.timeIntervalSinceNow * 1000
        var zs: [Float] = []
        for r in 0..<7 { for c in 0..<7 { zs += [Float(c) / 3 * 2 - 2, Float(r) / 3 * 2 - 2] } }
        map = m.decodeStyles(zs, label: label)
    }
}
