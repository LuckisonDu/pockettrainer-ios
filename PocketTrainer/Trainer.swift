// Trainer.swift —— 训练主循环 + 保护（影子校验）+ 存档/续训 + 给界面用的状态
import Foundation
import SwiftUI
import UIKit

struct CurvePoint: Identifiable { let step: Int; let acc: Double; var id: Int { step } }
struct LossPoint: Identifiable { let step: Int; let train: Double; let val: Double; var id: Int { step } }

enum Banner { case none, passed, unprotected, fixed(Int), failed(Double), finishedUnprotected }

/// 训练结束后写进 Documents/result.json 的结果（真机自动验证也读它）
struct RunResult: Codable {
    var tag: String, device: String, os: String
    var protect: Bool, seed: UInt64, lr: Double, hidden: Int, epochs: Int
    var interruptAt: Int, interruptFired: Bool, hangStatus: String
    var accuracy: Double, refAccuracy: Double, totalSteps: Int
    var flaggedSteps: Int, retries: Int, cpuFallbacks: Int
    var hangSeconds: Double?, trainEndAfterHang: Double?    // 超长任务被掐掉用了多久；训练结束时离打断过了多久
    var peakMemoryMB: Double, thermal: String, battery: Int   // 训练中最大内存；结束时发热状态；电量 %（-1 = 未知）
    var seconds: Double, weightsHash: String, resumedFrom: Int?
    var curve: [[Double]]
}

final class Trainer: ObservableObject {
    // ---- 界面上可调的设置
    @Published var lr = 0.05
    @Published var hidden = 512
    @Published var epochs = 8
    @Published var protect = true
    @Published var interruptArmed = false
    @Published var crashArmed = false
    // ---- 训练中的状态
    @Published var running = false
    @Published var computingReference = false
    @Published var step = 0
    @Published var totalSteps = 0
    @Published var elapsed = 0.0
    @Published var curve: [CurvePoint] = []
    @Published var previousCurve: [CurvePoint] = []   // 上一次运行的曲线（淡色叠加，方便对比）
    @Published var overlayPrevious = true
    // ---- 「Compare methods」和「Measure my phone's limit」的状态（逻辑在 Extras.swift）
    @Published var comparing = false
    @Published var compareRows: [CompareRow] = []
    @Published var compareNote = ""
    @Published var measuring = false
    @Published var limitText = ""
    @Published var fixes = 0
    @Published var banner = Banner.none
    @Published var result: RunResult?
    @Published var resumedFrom: Int?
    @Published var interruptFiredThisRun = false
    // ---- 给 Run 输出控制台和损失曲线用
    @Published var log: [String] = []
    @Published var lossPoints: [LossPoint] = []
    @Published var currentProject = ProjectStore.defaultProject
    var dataset = Dataset.shared               // 训练用的数据：默认是内置照片特征；表格项目会换成表格数据
    @Published var pendingResume: Session?      // 上次没训练完：等用户决定要不要续训（设置里「Offer resume on reopen」打开时）

    var seed: UInt64 = 1
    var tag = "manual"
    var paceMs = 0.0                   // 每步至少花多少毫秒（0 = 全速）；演示/实验用
    private var fireNow = false            // 训练中点了「模拟打断」按钮 → 下一步立刻打断

    var interruptUsedUp: Bool { Interruption.usedThisLaunch && !interruptFiredThisRun }

    /// 训练中再点一次打断按钮：立刻在下一步制造打断
    func interruptNow() { if running { fireNow = true } }

    // MARK: 开始 / 续训

    func start() {
        guard !running else { return }
        let total = dataset.trainCount / batchSize * epochs
        let at = Trainer.interruptStep(total: total, seed: seed)
        // 闪退点：55% 附近，且在两次存档之间（所以续训会「回退」几步重做）
        let every = Trainer.checkpointEvery
        let crash = (total * 55 / 100) / every * every + 7
        let cfg = Config(lr: lr, hidden: hidden, epochs: epochs, seed: seed, protect: protect,
                         interruptAt: interruptArmed && !Interruption.usedThisLaunch ? at : -1,
                         crashAt: crashArmed ? crash : -1, tag: tag, project: currentProject, tabular: dataset !== Dataset.shared)
        Store.clearSession()
        Store.saveSession(Session(config: cfg))
        launch(Session(config: cfg), resume: false)
    }

    /// App 启动时调用：上次没训练完（闪退/被杀）就自动接着训
    func resumeIfNeeded() {
        guard !running, let s = Store.loadSession() else { return }
        lr = s.config.lr; hidden = s.config.hidden; epochs = s.config.epochs; protect = s.config.protect
        seed = s.config.seed; tag = s.config.tag; currentProject = s.config.project ?? ProjectStore.defaultProject
        dataset = (s.config.tabular == true ? (try? TabularTools.buildDataset(project: currentProject).0) : nil) ?? Dataset.shared
        launch(s, resume: true)
    }

    private func launch(_ session: Session, resume: Bool) {
        if !curve.isEmpty && !resume { previousCurve = curve }
        running = true; step = 0; fixes = 0; curve = []; result = nil; resumedFrom = nil
        interruptFiredThisRun = false; elapsed = 0; lossPoints = []
        log = [resume ? tr("Resuming from the last checkpoint…") : tr("Run started: %ld epochs, learning rate %.3g, %ld hidden units", session.config.epochs, session.config.lr, session.config.hidden)]
        banner = session.config.protect ? .passed : .unprotected
        UIApplication.shared.isIdleTimerDisabled = true      // 训练时不要自动锁屏
        DispatchQueue.global(qos: .userInitiated).async { self.runLoop(session, resume: resume) }
    }

    /// 设置里的「Checkpoint interval」（每多少步存一次档，默认 20）和「Save checkpoints」开关
    static var checkpointEvery: Int { max(1, UserDefaults.standard.integer(forKey: "ckptInterval")) }
    static var saveCheckpoints: Bool { UserDefaults.standard.bool(forKey: "saveCheckpoints") }

    /// 随机选 30%~60% 处打断（用种子，结果可复现）
    static func interruptStep(total: Int, seed: UInt64) -> Int {
        var g = LCG(seed: seed &+ 777)
        return Int(Double(total) * (0.30 + 0.30 * Double((g.uniform() + 1) / 2)))
    }

    /// 保护开时的一步：GPU 算一次，和 CPU 影子比对；不一致 = 被污染，丢弃并在 GPU 重算（最多 3 次），还不对就改用 CPU 的结果。
    static func protectedStep(_ w: Weights, _ xb: [Float], _ yb: [Float], shadow ref: Weights, gpu: GPUNet)
        -> (w: Weights, flagged: Bool, retries: Int, fellBack: Bool) {
        func mismatch(_ r: Weights?) -> Double {
            guard let r else { return 1 }
            return max(updateMismatch(r.w1, ref.w1, w.w1), updateMismatch(r.w2, ref.w2, w.w2))
        }
        var res = gpu.step(w, xb, yb)
        if let r = res, mismatch(r) <= 1e-4 { return (r, false, 0, false) }      // 正常：一致
        var retries = 0
        for _ in 0..<3 {
            retries += 1
            res = gpu.step(w, xb, yb)
            if let r = res, mismatch(r) <= 1e-4 { return (r, true, retries, false) }
        }
        return (ref, true, retries, true)
    }

    // MARK: 训练主循环（在后台线程跑）

    private func runLoop(_ session: Session, resume: Bool) {
        var session = session
        let cfg = session.config
        let data = dataset
        let plan = Plan(seed: cfg.seed, hidden: cfg.hidden, epochs: cfg.epochs, trainCount: data.trainCount)
        let total = plan.totalSteps
        let cpu = CPUNet(H: cfg.hidden, lr: Float(cfg.lr))
        guard let gpu = GPUNet(hidden: cfg.hidden, lr: Float(cfg.lr)) else { return }

        var w = plan.initial, startStep = 0
        if resume, let (cw, st) = Store.loadCheckpoint(hidden: cfg.hidden) { w = cw; startStep = st }
        DispatchQueue.main.async {
            self.totalSteps = total; self.step = startStep
            self.resumedFrom = resume ? startStep : nil
        }

        var flagged = 0, retries = 0, fallbacks = 0, fired = false
        var points: [CurvePoint] = []
        var peakMB = SystemInfo.footprintMB()
        let t0 = Date()

        for i in startStep..<total {
            let stepStart = Date()
            autoreleasepool {      // ★每步一个 autoreleasepool：不释放的话约 200 步后内存撑爆被系统杀掉
                let (xb, yb) = plan.batch(i, data)

                // 保护开：先在 CPU 上算「标准答案」（影子）
                let shadow: Weights? = cfg.protect ? cpu.step(w, xb, yb) : nil

                // 模拟系统打断：和这一步的 GPU 计算同时，提交一个超长 GPU 任务
                if (i == cfg.interruptAt || fireNow) && !Interruption.usedThisLaunch {
                    fireNow = false; fired = true
                    Interruption.fire()
                    DispatchQueue.main.async { self.interruptFiredThisRun = true }
                }

                if let ref = shadow {
                    // 保护开：比对 GPU 与 CPU，不一致就丢弃重算（细节见 protectedStep）
                    let out = Trainer.protectedStep(w, xb, yb, shadow: ref, gpu: gpu)
                    w = out.w; retries += out.retries
                    if out.fellBack { fallbacks += 1 }
                    if out.flagged {
                        flagged += 1
                        let n = flagged
                        DispatchQueue.main.async { self.fixes = n; self.banner = .fixed(n) }
                    }
                } else if let r = gpu.step(w, xb, yb) {
                    w = r                                       // 保护关：GPU 给什么就直接用什么
                }

                // 每 N 步原子存档（N 和开关在设置里，默认每 20 步、开）
                if Trainer.saveCheckpoints && (i + 1) % Trainer.checkpointEvery == 0 { Store.saveCheckpoint(w, step: i + 1) }

                // 每 10 步在测试集上量一次准确率，画曲线
                if (i + 1) % 10 == 0 || i + 1 == total {
                    peakMB = max(peakMB, SystemInfo.footprintMB())
                    let ev = cpu.evaluate(w, data), acc = ev.acc
                    let trainLoss = cpu.batchLoss(w, xb, yb)
                    points.append(CurvePoint(step: i + 1, acc: acc))
                    let dt = -t0.timeIntervalSinceNow, s = i + 1
                    DispatchQueue.main.async {
                        self.curve.append(CurvePoint(step: s, acc: acc)); self.elapsed = dt
                        self.lossPoints.append(LossPoint(step: s, train: trainLoss, val: ev.loss))
                        self.log.append(tr("Step %ld/%ld  loss: %.3f  val_loss: %.3f  val_acc: %.1f%%", s, total, trainLoss, ev.loss, acc * 100))
                    }
                }
                let s = i + 1
                DispatchQueue.main.async { self.step = s }

                // 模拟闪退：存档之后让进程自杀（只自杀一次）
                if i == cfg.crashAt && !session.crashDone {
                    session.crashDone = true; Store.saveSession(session)
                    kill(getpid(), SIGKILL)
                }
            }
            let left = paceMs / 1000 + stepStart.timeIntervalSinceNow
            if left > 0 { Thread.sleep(forTimeInterval: left) }
        }

        let seconds = -t0.timeIntervalSinceNow
        peakMB = max(peakMB, SystemInfo.footprintMB())
        let finalAcc = cpu.accuracy(w, data)
        let finalHash = Store.hash(w)
        let finalW = w
        DispatchQueue.main.async { self.computingReference = true; self.elapsed = seconds }

        // 参考：整个训练全程只用 CPU 再跑一遍（确定性），作为「正确答案」
        var rw = plan.initial
        for i in 0..<total { autoreleasepool { let (xb, yb) = plan.batch(i, data); rw = cpu.step(rw, xb, yb) } }
        let refAcc = cpu.accuracy(rw, data)

        var info = utsname(); uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
        let r = RunResult(tag: cfg.tag, device: machine, os: UIDevice.current.systemVersion,
                          protect: cfg.protect, seed: cfg.seed, lr: cfg.lr, hidden: cfg.hidden, epochs: cfg.epochs,
                          interruptAt: cfg.interruptAt, interruptFired: fired, hangStatus: Interruption.lastStatus,
                          accuracy: finalAcc, refAccuracy: refAcc, totalSteps: total,
                          flaggedSteps: flagged, retries: retries, cpuFallbacks: fallbacks,
                          hangSeconds: Interruption.doneAt.flatMap { d in Interruption.firedAt.map { d.timeIntervalSince($0) } },
                          trainEndAfterHang: Interruption.firedAt.map { t0.addingTimeInterval(seconds).timeIntervalSince($0) },
                          peakMemoryMB: peakMB, thermal: SystemInfo.thermalName, battery: SystemInfo.batteryPercent,
                          seconds: seconds, weightsHash: finalHash, resumedFrom: resume ? startStep : nil,
                          curve: points.map { [Double($0.step), $0.acc] })
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: Store.resultURL, options: .atomic) }
        Store.clearSession()

        DispatchQueue.main.async {
            self.result = r; self.running = false; self.computingReference = false
            self.finishLog(r, flagged: flagged, finalAcc: finalAcc, refAcc: refAcc, finalWeights: finalW, project: cfg.project ?? self.currentProject)
            UIApplication.shared.isIdleTimerDisabled = false
            if cfg.protect { self.banner = flagged > 0 ? .fixed(flagged) : .passed }
            else { self.banner = finalAcc < refAcc - 0.10 ? .failed(finalAcc) : .finishedUnprotected }
        }
    }
}

extension Trainer {
    /// 训练结束：往 Output 控制台写总结，记进「最近运行」，并把最终权重存成项目里的检查点文件
    func finishLog(_ r: RunResult, flagged: Int, finalAcc: Double, refAcc: Double, finalWeights: Weights, project: String) {
        log.append(tr("Validation: OK"))
        log.append(dataset === Dataset.shared ? tr("Test accuracy: %.1f%% (2,000 photos the model never saw)", finalAcc * 100) : tr("Test accuracy: %.1f%% (%ld rows the model never saw)", finalAcc * 100, dataset.testCount))
        if r.protect { log.append(flagged > 0 ? tr("⚠ Error detected and fixed (%ld)", flagged) : tr("✓ Verified")) }
        else { log.append(finalAcc < refAcc - 0.10 ? tr("✗ Verification is off — the result is wrong (CPU reference %ld%%)", Int(refAcc * 100)) : tr("Verification is off")) }
        let last = lossPoints.last
        RunHistory.add(RunRecord(date: Date(), project: project, accuracy: finalAcc, refAccuracy: refAcc, protect: r.protect, fixed: flagged,
                                 lr: r.lr, hidden: r.hidden, epochs: r.epochs, seconds: r.seconds,
                                 firstLoss: lossPoints.first?.train ?? 0, lastLoss: last?.train ?? 0, lastValLoss: last?.val ?? 0, resumed: r.resumedFrom != nil))
        ProjectStore.saveFinalCheckpoint(finalWeights, step: r.totalSteps, project: project)
    }
}
