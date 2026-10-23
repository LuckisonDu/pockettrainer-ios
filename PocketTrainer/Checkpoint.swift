// Checkpoint.swift —— 原子存档 + 续训记录
// 存档规则：先写 .tmp 文件并强制落盘，再「原子替换」正式文件。
// 这样无论何时闪退/断电，磁盘上要么是完整的旧存档，要么是完整的新存档，不会是写到一半的坏文件。
import Foundation

/// 一次训练的全部设置（存进 session.json，续训时原样恢复）
struct Config: Codable {
    var lr: Double, hidden: Int, epochs: Int, seed: UInt64
    var protect: Bool
    var interruptAt: Int    // 在第几步制造系统打断；-1 = 不打断
    var crashAt: Int        // 在第几步让进程自杀；-1 = 不
    var tag: String
    var project: String? = nil     // 属于哪个项目（旧存档没有这项，所以是可选的）
    var tabular: Bool? = nil       // 训练的是表格数据（续训时要重新读表格）
}

struct Session: Codable {
    var config: Config
    var crashDone: Bool = false
}

enum Store {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let ckptURL = docs.appendingPathComponent("pt_ckpt.bin")
    static let sessionURL = docs.appendingPathComponent("pt_session.json")
    static let resultURL = docs.appendingPathComponent("result.json")

    /// FNV 校验和（简单的指纹，用来发现存档损坏、也用来比较两份权重是否逐位相同）
    static func fnv(_ d: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in d { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// 打包：[步数 4 字节][w1][b1][w2][b2][校验 8 字节]
    static func pack(_ w: Weights, step: Int) -> Data {
        var d = Data()
        var st = UInt32(step)
        withUnsafeBytes(of: &st) { d.append(contentsOf: $0) }
        for a in [w.w1, w.b1, w.w2, w.b2] { a.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
        var h = fnv(d)
        withUnsafeBytes(of: &h) { d.append(contentsOf: $0) }
        return d
    }

    /// 权重指纹（十六进制）：两次训练指纹相同 = 权重逐位相同
    static func hash(_ w: Weights) -> String { String(fnv(pack(w, step: 0)), radix: 16) }

    static func saveCheckpoint(_ w: Weights, step: Int) {
        let tmp = ckptURL.appendingPathExtension("tmp"), fm = FileManager.default
        do {
            try pack(w, step: step).write(to: tmp)
            if let h = try? FileHandle(forWritingTo: tmp) { try? h.synchronize(); try? h.close() }   // 强制落盘
            if fm.fileExists(atPath: ckptURL.path) { _ = try fm.replaceItemAt(ckptURL, withItemAt: tmp) }  // 原子替换
            else { try fm.moveItem(at: tmp, to: ckptURL) }
        } catch { print("checkpoint save failed: \(error)") }
    }

    /// 读存档；文件坏了（校验不对）就返回 nil，从头开始
    static func loadCheckpoint(hidden H: Int) -> (Weights, Int)? {
        guard let d = try? Data(contentsOf: ckptURL), d.count > 20 else { return nil }
        let body = d.prefix(d.count - 8)
        let stored = d.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard fnv(Data(body)) == stored else { return nil }
        let step = Int(body.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        var off = 4
        func take(_ n: Int) -> [Float] {
            var o = [Float](repeating: 0, count: n)
            _ = o.withUnsafeMutableBytes { body.subdata(in: (body.startIndex + off)..<(body.startIndex + off + n * 4)).copyBytes(to: $0) }
            off += n * 4
            return o
        }
        guard body.count == 4 + (featureDim * H + H + H * numClasses + numClasses) * 4 else { return nil }
        return (Weights(w1: take(featureDim * H), b1: take(H), w2: take(H * numClasses), b2: take(numClasses)), step)
    }

    static func saveSession(_ s: Session) { try? JSONEncoder().encode(s).write(to: sessionURL, options: .atomic) }
    static func loadSession() -> Session? {
        guard let d = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }
    static func clearSession() {
        try? FileManager.default.removeItem(at: sessionURL)
        try? FileManager.default.removeItem(at: ckptURL)
    }
}
