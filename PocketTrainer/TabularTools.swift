// TabularTools.swift —— 表格数据（CSV / JSONL）→ 设备端训练
// 数值列直接当特征（标准化后补零到 2048 维，这样可以原样用我们的训练内核和保护），标签列最多 10 类。
import Foundation

struct TableData {
    var columns: [String]
    var rows: [[String]]
    var numeric: [Bool]          // 这一列是不是全是数字
    func distinct(_ c: Int) -> Int { Set(rows.map { $0[c] }).count }
}

enum TabularTools {
    struct Failure: LocalizedError { let errorDescription: String? }
    struct Config: Codable { var file: String, label: String, features: [String] }
    static let maxRows = 8000

    /// 项目里的表格文件（根目录里的 csv/jsonl，和用户下载到 models/ 里的）
    static func candidates(project: String) -> [String] {
        let root = ProjectStore.dir(project)
        var out = ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).filter { p in
            let e = (p as NSString).pathExtension.lowercased(); return (e == "csv" || e == "jsonl") && !p.hasPrefix(".") }
        // HF 数据集里还没下载的大表格（导入记录里列出的）
        if let d = try? Data(contentsOf: root.appendingPathComponent(".pt_import.json")), let rec = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for w in rec["weights"] as? [[String: Any]] ?? [] { if let p = w["path"] as? String, p.hasSuffix(".csv") || p.hasSuffix(".jsonl"), !out.contains("models/" + p.replacingOccurrences(of: "/", with: "_")) { out.append(p) } }
        }
        return out.sorted()
    }

    // MARK: 读文件

    static func load(project: String, rel: String) throws -> TableData {
        let url = ProjectStore.dir(project).appendingPathComponent(rel)
        guard let d = try? Data(contentsOf: url), d.count <= GitHubImport.maxTable, let text = String(data: d, encoding: .utf8) else {
            throw Failure(errorDescription: tr("Could not read this table (not found, not text, or larger than 5 MB).")) }
        let table = rel.hasSuffix(".jsonl") ? parseJSONL(text) : parseCSV(text)
        guard table.columns.count >= 2, table.rows.count >= 10 else { throw Failure(errorDescription: tr("The table needs at least 2 columns and 10 rows.")) }
        return table
    }

    static func parseCSV(_ text: String) -> TableData {
        var rows: [[String]] = [], row: [String] = [], field = "", inQ = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQ { if c == "\"" { if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append(c); i += 1 } else { inQ = false } } else { field.unicodeScalars.append(c) } }
            else if c == "\"" { inQ = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r" { if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }; row.append(field); field = ""; if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }; row = [] }
            else { field.unicodeScalars.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard let head = rows.first else { return TableData(columns: [], rows: [], numeric: []) }
        let body = rows.dropFirst().filter { $0.count == head.count }.prefix(maxRows)
        return make(head.map { $0.trimmingCharacters(in: .whitespaces) }, Array(body))
    }

    static func parseJSONL(_ text: String) -> TableData {
        let objs = text.split(separator: "\n").prefix(maxRows).compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        var cols: [String] = []
        for o in objs.prefix(100) { for k in o.keys.sorted() where !cols.contains(k) { cols.append(k) } }
        let rows = objs.map { o in cols.map { k -> String in
            switch o[k] { case let n as NSNumber: return n.stringValue; case let s as String: return s; default: return "" } } }
        return make(cols, rows)
    }

    private static func make(_ cols: [String], _ rows: [[String]]) -> TableData {
        let numeric = cols.indices.map { c in rows.allSatisfy { Double($0[c].trimmingCharacters(in: .whitespaces)) != nil } }
        return TableData(columns: cols, rows: rows, numeric: numeric)
    }

    /// 猜标签列：从右往左找第一个「2~10 种不同取值」的列
    static func guessLabel(_ t: TableData) -> Int { t.columns.indices.reversed().first { (2...10).contains(t.distinct($0)) } ?? t.columns.count - 1 }

    // MARK: 配置 + 做成训练数据集

    static func config(project: String) -> Config? {
        (try? Data(contentsOf: ProjectStore.dir(project).appendingPathComponent("data/tabular.json"))).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }
    static func saveConfig(_ c: Config, project: String) {
        let dir = ProjectStore.dir(project).appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(c).write(to: dir.appendingPathComponent("tabular.json"))
    }

    /// 标准化 → 补零到 2048 维 → 80/20 切分 → 训练集重复到凑满整数个批次
    static func buildDataset(project: String) throws -> (Dataset, classes: [String]) {
        guard let cfg = config(project: project) else { throw Failure(errorDescription: tr("No table is set up for training in this project.")) }
        let t = try load(project: project, rel: cfg.file)
        guard let li = t.columns.firstIndex(of: cfg.label) else { throw Failure(errorDescription: tr("The label column was not found.")) }
        let fi = cfg.features.compactMap { t.columns.firstIndex(of: $0) }.filter { t.numeric[$0] && $0 != li }
        guard !fi.isEmpty, fi.count <= featureDim else { throw Failure(errorDescription: tr("Pick at least one number column as a feature.")) }
        let classes = Array(Set(t.rows.map { $0[li] })).sorted()
        guard (2...numClasses).contains(classes.count) else { throw Failure(errorDescription: tr("The label column must have between 2 and 10 different values.")) }
        // 固定种子洗牌
        var g = LCG(seed: 7), idx = Array(0..<t.rows.count)
        for i in stride(from: idx.count - 1, to: 0, by: -1) { idx.swapAt(i, Int((g.next() >> 33) % UInt64(i + 1))) }
        let nTest = max(5, idx.count / 5), test = Array(idx.prefix(nTest)), train = Array(idx.dropFirst(nTest))
        // 用训练行算均值和标准差
        var mean = [Double](repeating: 0, count: fi.count), sd = [Double](repeating: 0, count: fi.count)
        for (k, c) in fi.enumerated() { let v = train.map { Double(t.rows[$0][c]) ?? 0 }; mean[k] = v.reduce(0, +) / Double(v.count); sd[k] = max((v.map { ($0 - mean[k]) * ($0 - mean[k]) }.reduce(0, +) / Double(v.count)).squareRoot(), 1e-6) }
        func feats(_ r: Int, into x: inout [Float], at o: Int) { for (k, c) in fi.enumerated() { x[o + k] = Float(((Double(t.rows[r][c]) ?? 0) - mean[k]) / sd[k]) } }
        let steps = max(1, (train.count + batchSize - 1) / batchSize), nTrain = steps * batchSize      // 重复训练行凑满批次
        var tx = [Float](repeating: 0, count: nTrain * featureDim), ty = [UInt8](repeating: 0, count: nTrain)
        for i in 0..<nTrain { let r = train[i % train.count]; feats(r, into: &tx, at: i * featureDim); ty[i] = UInt8(classes.firstIndex(of: t.rows[r][li]) ?? 0) }
        var ex = [Float](repeating: 0, count: test.count * featureDim), ey = [UInt8](repeating: 0, count: test.count)
        for (i, r) in test.enumerated() { feats(r, into: &ex, at: i * featureDim); ey[i] = UInt8(classes.firstIndex(of: t.rows[r][li]) ?? 0) }
        return (Dataset(trainX: tx, trainY: ty, testX: ex, testY: ey), classes)
    }
}
