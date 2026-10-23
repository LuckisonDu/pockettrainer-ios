// RunHistory.swift —— 「最近运行」记录：每次训练结束存一条，首页 / Notes / Coach 都从这里读
import Foundation

struct RunRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var project: String
    var accuracy: Double, refAccuracy: Double
    var protect: Bool, fixed: Int
    var lr: Double, hidden: Int, epochs: Int, seconds: Double
    var firstLoss: Double, lastLoss: Double, lastValLoss: Double   // 训练损失的第一个/最后一个点；验证损失最后一个点
    var resumed: Bool

    /// 一句话总结（首页 Latest runs 用）
    var summary: String {
        let acc = String(format: "%.1f%%", accuracy * 100)
        if !protect { return accuracy < refAccuracy - 0.10 ? tr("%@ · protection off · result wrong", acc) : tr("%@ · protection off", acc) }
        return fixed > 0 ? tr("%@ · errors fixed automatically: %ld", acc, fixed) : tr("%@ · verified", acc)
    }
}

enum RunHistory {
    static let url = Store.docs.appendingPathComponent("runs.json")

    static func all() -> [RunRecord] {      // 新的在前
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([RunRecord].self, from: d)) ?? []
    }

    static func add(_ r: RunRecord) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let list = Array(([r] + all()).prefix(50))
        try? enc.encode(list).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: .runHistoryChanged, object: nil)
    }
}

extension Notification.Name { static let runHistoryChanged = Notification.Name("runHistoryChanged") }
