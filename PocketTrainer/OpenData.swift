// OpenData.swift —— 项目的「数据」：从开放数据网站（Hugging Face）挑一个小数据集，下载到项目的 data/ 里，用来训练。
// 表格（CSV）直接下载文件；图片数据集（MNIST / Fashion-MNIST）用 Hugging Face 的 datasets-server 按行取图片，每张 28×28 灰度。
// 只在用户点「Download」时上网，只去 huggingface.co 和 datasets-server.huggingface.co。
// 说明：本文件由 AI（Claude）编写，须在国会 AI 披露里写明。
import Foundation
import CoreGraphics
import ImageIO

/// 目录里的一个开放数据集
struct OpenDataset: Identifiable, Hashable {
    enum Kind: String { case table, images }
    let id: String, title: String, kind: Kind
    let repo: String, file: String          // table：仓库里的 CSV 文件；images：datasets-server 的 config
    let split: String, label: String        // images：split；label 列名（table 用它当标签）
    let license: String, blurb: String
    let count: Int                          // 下载多少行 / 张（images）；table 为整份文件
    var pageURL: String { "https://huggingface.co/datasets/" + repo }

    static let catalog: [OpenDataset] = [
        OpenDataset(id: "mnist", title: "Handwritten digits (MNIST)", kind: .images, repo: "ylecun/mnist", file: "mnist", split: "train", label: "label",
                    license: "MIT", blurb: "28×28 pictures of the digits 0–9 written by hand.", count: 2000),
        OpenDataset(id: "fashion", title: "Clothes pictures (Fashion-MNIST)", kind: .images, repo: "zalando-datasets/fashion_mnist", file: "fashion_mnist", split: "train", label: "label",
                    license: "MIT", blurb: "28×28 pictures of 10 kinds of clothes and shoes.", count: 2000),
        OpenDataset(id: "iris", title: "Iris flowers", kind: .table, repo: "scikit-learn/iris", file: "Iris.csv", split: "", label: "Species",
                    license: "CC0-1.0", blurb: "150 flowers, 4 measurements each, 3 species.", count: 0),
        OpenDataset(id: "fish", title: "Fish species", kind: .table, repo: "scikit-learn/Fish", file: "Fish.csv", split: "", label: "Species",
                    license: "CC-BY-4.0", blurb: "159 fish, weight and size, 7 species.", count: 0),
        OpenDataset(id: "cancer", title: "Breast cancer diagnosis", kind: .table, repo: "scikit-learn/breast-cancer-wisconsin", file: "breast_cancer.csv", split: "", label: "diagnosis",
                    license: "CC-BY-SA-4.0", blurb: "569 cell samples, 30 measurements, benign or malignant.", count: 0),
        OpenDataset(id: "penguins", title: "Penguin species", kind: .table, repo: "SIH/palmer-penguins", file: "penguins.csv", split: "", label: "species",
                    license: "CC0-1.0", blurb: "344 penguins from Antarctica, bill and flipper sizes, 3 species.", count: 0),
    ]

    /// 选了这份数据后，配方里建议的三个数（总步数大约 200 步，手机上十几秒训完）
    func suggested(trainRows: Int) -> (hidden: Int, lr: Double, epochs: Int) {
        let perEpoch = max(1, (trainRows + batchSize - 1) / batchSize)
        return kind == .images ? (128, 0.1, max(5, 200 / perEpoch)) : (32, 0.1, min(300, max(5, 200 / perEpoch)))
    }
}

/// Hugging Face 网站上这份数据的实时信息（下载量、点赞、许可证）
struct LiveInfo { var downloads: Int?, likes: Int?, license: String? }

/// 项目里已有的数据（data/source.json）
struct DataSource: Codable {
    var id: String, title: String, kind: String, repo: String, url: String, license: String
    var count: Int, classes: [String], label: String, downloaded: Double
    var width: Int?, height: Int?, file: String?
}

enum ProjectData {
    struct Failure: LocalizedError { let errorDescription: String? }
    static let side = 28

    static func dir(_ project: String) -> URL { ProjectStore.dir(project).appendingPathComponent("data", isDirectory: true) }
    static func source(_ project: String) -> DataSource? {
        (try? Data(contentsOf: dir(project).appendingPathComponent("source.json"))).flatMap { try? JSONDecoder().decode(DataSource.self, from: $0) }
    }
    static func isImages(_ project: String) -> Bool { source(project)?.kind == "images" }

    /// 这个项目现在用哪份数据（训练时记下来；结果页据此判断「模型是不是用现在这份数据训的」）
    static func dataKey(_ project: String) -> String {
        if let s = source(project) { return "hf:" + s.id }
        if let c = TabularTools.config(project: project) { return "table:" + c.file }
        return "builtin"
    }
    static func stampURL(_ project: String) -> URL { ProjectStore.dir(project).appendingPathComponent("checkpoints/trained_on.txt") }
    static func stampTrained(_ project: String) { try? dataKey(project).write(to: stampURL(project), atomically: true, encoding: .utf8) }
    /// 最近一次训练用的数据；旧版本没记的当作内置数据
    static func trainedOn(_ project: String) -> String { (try? String(contentsOf: stampURL(project), encoding: .utf8)) ?? "builtin" }

    /// 改回内置的 CIFAR-10 照片特征（不删已下载的文件，只是不再用它们训练）
    static func useBuiltin(_ project: String) {
        for f in ["source.json", "tabular.json", "images.u8", "labels.u8"] { try? FileManager.default.removeItem(at: dir(project).appendingPathComponent(f)) }
    }

    /// 打开数据列表时上网查一次 Hugging Face 上的实时信息
    static func liveInfo(_ ds: OpenDataset) async -> LiveInfo {
        guard let u = URL(string: "https://huggingface.co/api/datasets/" + ds.repo), let d = try? await GitHubImport.get(u),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return LiveInfo() }
        let card = j["cardData"] as? [String: Any]
        let lic = (card?["license"] as? String) ?? (card?["license"] as? [String])?.first
        return LiveInfo(downloads: j["downloads"] as? Int, likes: j["likes"] as? Int, license: lic)
    }

    /// 选好数据后，把配方（code/model.py）里的三个数改成适合这份数据的值；返回说明
    @discardableResult
    static func applySuggested(_ ds: OpenDataset, trainRows: Int, project: String) -> String? {
        guard let rel = ProjectStore.recipePath(project) else { return nil }
        let r = ds.suggested(trainRows: trainRows)
        var t = FileStore.read(project, rel)
        t = ConfigCode.set("hidden_units", String(r.hidden), in: t)
        t = ConfigCode.set("learning_rate", String(r.lr), in: t)
        t = ConfigCode.set("epochs", String(r.epochs), in: t)
        FileStore.write(project, rel, t)
        return tr("Recipe set for this data: hidden_units %ld, learning_rate %@, epochs %ld", r.hidden, String(r.lr), r.epochs)
    }

    // MARK: 下载

    /// 下载并存进项目；progress(已完成, 总数, 说明)
    static func download(_ ds: OpenDataset, project: String, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> DataSource {
        try FileManager.default.createDirectory(at: dir(project), withIntermediateDirectories: true)
        if let src = fromCache(ds, project: project) { progress(1, 1, tr("Using the copy already on this phone")); return src }
        let src: DataSource
        switch ds.kind {
        case .table: src = try await downloadTable(ds, project: project, progress: progress)
        case .images: src = try await downloadImages(ds, project: project, progress: progress)
        }
        saveCache(src, project: project)
        return src
    }

    // MARK: 手机上的数据缓存：同一份数据下载过一次，别的项目再选它就直接复制（不重复上网，也不怕网站限流）

    static let cacheRoot = Store.docs.appendingPathComponent("OpenDataCache", isDirectory: true)
    private static func cacheFiles(_ s: DataSource) -> [String] {
        s.kind == "images" ? ["images.u8", "labels.u8", "source.json"] : [((s.file ?? "") as NSString).lastPathComponent, "tabular.json", "source.json"]
    }
    private static func saveCache(_ s: DataSource, project: String) {
        let c = cacheRoot.appendingPathComponent(s.id, isDirectory: true), fm = FileManager.default
        try? fm.removeItem(at: c); try? fm.createDirectory(at: c, withIntermediateDirectories: true)
        for f in cacheFiles(s) { try? fm.copyItem(at: dir(project).appendingPathComponent(f), to: c.appendingPathComponent(f)) }
    }
    private static func fromCache(_ ds: OpenDataset, project: String) -> DataSource? {
        let c = cacheRoot.appendingPathComponent(ds.id, isDirectory: true), fm = FileManager.default
        guard let d = try? Data(contentsOf: c.appendingPathComponent("source.json")), let s = try? JSONDecoder().decode(DataSource.self, from: d),
              cacheFiles(s).allSatisfy({ fm.fileExists(atPath: c.appendingPathComponent($0).path) }) else { return nil }
        for f in cacheFiles(s) {
            let to = dir(project).appendingPathComponent(f)
            try? fm.removeItem(at: to)
            guard (try? fm.copyItem(at: c.appendingPathComponent(f), to: to)) != nil else { return nil }
        }
        for f in (s.kind == "images" ? ["tabular.json"] : ["images.u8", "labels.u8"]) { try? fm.removeItem(at: dir(project).appendingPathComponent(f)) }
        return s
    }

    private static func downloadTable(_ ds: OpenDataset, project: String, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> DataSource {
        progress(0, 1, tr("Downloading %@ …", ds.file))
        guard let u = URL(string: "https://huggingface.co/datasets/\(ds.repo)/resolve/main/\(ds.file)") else { throw Failure(errorDescription: "bad url") }
        let d = try await hfGet(u)
        guard d.count <= GitHubImport.maxTable else { throw Failure(errorDescription: tr("This table is larger than 5 MB.")) }
        let name = (ds.file as NSString).lastPathComponent, rel = "data/" + name
        try d.write(to: ProjectStore.dir(project).appendingPathComponent(rel), options: .atomic)
        let t = try TabularTools.load(project: project, rel: rel)
        let li = t.columns.firstIndex(of: ds.label) ?? TabularTools.guessLabel(t)
        let feats = t.columns.indices.filter { t.numeric[$0] && $0 != li && !["id", "Id", "ID"].contains(t.columns[$0]) }.map { t.columns[$0] }
        TabularTools.saveConfig(.init(file: rel, label: t.columns[li], features: feats), project: project)
        try? FileManager.default.removeItem(at: dir(project).appendingPathComponent("images.u8"))
        let classes = Array(Set(t.rows.map { $0[li] })).sorted()
        let src = DataSource(id: ds.id, title: ds.title, kind: "table", repo: ds.repo, url: ds.pageURL, license: ds.license, count: t.rows.count,
                             classes: classes, label: t.columns[li], downloaded: Date().timeIntervalSince1970, width: nil, height: nil, file: rel)
        try save(src, project: project)
        progress(1, 1, tr("Done"))
        return src
    }

    private static func downloadImages(_ ds: OpenDataset, project: String, progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> DataSource {
        let base = "https://datasets-server.huggingface.co/rows?dataset=\(ds.repo)&config=\(ds.file)&split=\(ds.split)"
        var items: [(url: URL, label: Int)] = []; var names: [String] = []
        var offset = 0
        while items.count < ds.count {
            progress(items.count, ds.count, tr("Listing pictures on Hugging Face …"))
            guard let u = URL(string: base + "&offset=\(offset)&length=100") else { break }
            guard let j = try JSONSerialization.jsonObject(with: try await hfGet(u)) as? [String: Any], let rows = j["rows"] as? [[String: Any]], !rows.isEmpty else { break }
            if names.isEmpty, let feats = j["features"] as? [[String: Any]],
               let lf = feats.first(where: { $0["name"] as? String == ds.label }), let ty = lf["type"] as? [String: Any], let n = ty["names"] as? [String] { names = n }
            for r in rows {
                guard let row = r["row"] as? [String: Any], let img = row["image"] as? [String: Any], let s = img["src"] as? String, let url = URL(string: s),
                      let lab = row[ds.label] as? Int else { continue }
                items.append((url, lab))
            }
            offset += rows.count
        }
        items = Array(items.prefix(ds.count))
        guard items.count >= 100 else { throw Failure(errorDescription: tr("Could not get enough pictures from Hugging Face.")) }
        // 并发下载 + 解码成 28×28 灰度
        let n = items.count, px = side * side
        var pixels = [UInt8](repeating: 0, count: n * px), labels = [UInt8](repeating: 0, count: n), ok = [Bool](repeating: false, count: n)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, [UInt8]?).self) { group in
            var next = 0
            while next < min(8, n) {
                let i = next, u = items[i].url; next += 1
                group.addTask { (i, await fetchGray(u)) }
            }
            while let (i, g) = try await group.next() {
                if let g { pixels.replaceSubrange(i * px..<(i + 1) * px, with: g); labels[i] = UInt8(clamping: items[i].label); ok[i] = true }
                done += 1
                if done % 50 == 0 || done == n { progress(done, n, tr("Downloading pictures %ld / %ld", done, n)) }
                if next < n {
                    let j = next, u = items[j].url; next += 1
                    group.addTask { (j, await fetchGray(u)) }
                }
            }
        }
        // 没下到的图不能留成全黑 + 标签 0（会悄悄弄脏训练数据）：丢掉；丢太多就报错
        let good = ok.indices.filter { ok[$0] }
        guard good.count >= n * 95 / 100 else { throw Failure(errorDescription: tr("Only %ld of %ld pictures could be downloaded. Please try again in a minute.", good.count, n)) }
        if good.count < n {
            pixels = good.flatMap { pixels[($0 * px)..<(($0 + 1) * px)] }; labels = good.map { labels[$0] }
        }
        try Data(pixels).write(to: dir(project).appendingPathComponent("images.u8"), options: .atomic)
        try Data(labels).write(to: dir(project).appendingPathComponent("labels.u8"), options: .atomic)
        try? FileManager.default.removeItem(at: dir(project).appendingPathComponent("tabular.json"))
        let classes = names.isEmpty ? (0..<10).map(String.init) : names
        let src = DataSource(id: ds.id, title: ds.title, kind: "images", repo: ds.repo, url: ds.pageURL, license: ds.license, count: good.count,
                             classes: classes, label: ds.label, downloaded: Date().timeIntervalSince1970, width: side, height: side, file: "data/images.u8")
        try save(src, project: project)
        return src
    }

    /// 结果页上显示的类别名：有的数据集只存代号（乳腺癌 B / M），换成看得懂的词
    static let prettyNames: [String: [String: String]] = ["cancer": ["B": "Benign (B)", "M": "Malignant (M)"]]
    static func display(_ cls: String, project: String) -> String { prettyNames[source(project)?.id ?? ""]?[cls] ?? cls }

    /// 从 Hugging Face 取数据：它的数据接口偶尔回 502 / 超时 / 限流，最多试 5 次（等 1、2、4、8 秒）
    static func hfGet(_ u: URL) async throws -> Data {
        for t in 0..<5 {
            if let d = try? await GitHubImport.get(u) { return d }
            if t < 4 { try? await Task.sleep(nanoseconds: UInt64(1 << t) * 1_000_000_000) }
        }
        throw Failure(errorDescription: tr("Hugging Face is busy or cannot be reached right now. Please try again in a minute."))
    }

    private static func save(_ s: DataSource, project: String) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(s).write(to: dir(project).appendingPathComponent("source.json"), options: .atomic)
    }

    /// 下载一张图并转成 28×28 灰度；失败最多重试 3 次
    static func fetchGray(_ u: URL) async -> [UInt8]? {
        for t in 0..<4 {
            if let d = try? await GitHubImport.get(u), let g = gray28(d) { return g }
            try? await Task.sleep(nanoseconds: UInt64(t + 1) * 700_000_000)
        }
        return nil
    }

    /// 任意图片 → 28×28 灰度（0 = 黑）
    static func gray28(_ data: Data) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var out = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &out, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        return out
    }

    // MARK: 读回来训练 / 看结果

    struct Images { let pixels: [UInt8], labels: [UInt8], count: Int, classes: [String] }
    static func images(_ project: String) -> Images? {
        guard let s = source(project), s.kind == "images",
              let p = try? Data(contentsOf: dir(project).appendingPathComponent("images.u8")), let l = try? Data(contentsOf: dir(project).appendingPathComponent("labels.u8")),
              p.count == l.count * side * side else { return nil }
        return Images(pixels: [UInt8](p), labels: [UInt8](l), count: l.count, classes: s.classes)
    }

    /// 固定种子把下标分成训练 / 测试（80 / 20）；结果页用同一个切分
    static func split(_ n: Int) -> (train: [Int], test: [Int]) {
        var g = LCG(seed: 7), idx = Array(0..<n)
        for i in stride(from: idx.count - 1, to: 0, by: -1) { idx.swapAt(i, Int((g.next() >> 33) % UInt64(i + 1))) }
        let nTest = max(5, n / 5); return (Array(idx.dropFirst(nTest)), Array(idx.prefix(nTest)))
    }

    /// 图片数据集 → 训练用 Dataset（784 个像素 0~1，补零到 2048 维）
    static func imageDataset(project: String) throws -> (Dataset, classes: [String]) {
        guard let im = images(project) else { throw Failure(errorDescription: tr("No pictures are set up for training in this project.")) }
        let px = side * side, (train, test) = split(im.count)
        let steps = max(1, (train.count + batchSize - 1) / batchSize), nTrain = steps * batchSize
        var tx = [Float](repeating: 0, count: nTrain * featureDim), ty = [UInt8](repeating: 0, count: nTrain)
        for i in 0..<nTrain { let r = train[i % train.count]; for k in 0..<px { tx[i * featureDim + k] = Float(im.pixels[r * px + k]) / 255 }; ty[i] = im.labels[r] }
        var ex = [Float](repeating: 0, count: test.count * featureDim), ey = [UInt8](repeating: 0, count: test.count)
        for (i, r) in test.enumerated() { for k in 0..<px { ex[i * featureDim + k] = Float(im.pixels[r * px + k]) / 255 }; ey[i] = im.labels[r] }
        return (Dataset(trainX: tx, trainY: ty, testX: ex, testY: ey), im.classes)
    }

    /// 这个项目训练用哪份数据：图片 → 表格 → 内置照片特征
    static func trainingDataset(project: String) throws -> Dataset {
        if isImages(project) { return try imageDataset(project: project).0 }
        if TabularTools.config(project: project) != nil { return try TabularTools.buildDataset(project: project).0 }
        return Dataset.shared
    }
}
