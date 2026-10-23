// Extras.swift —— 三个附加功能：
//   1. Compare methods：同一次打断，三种做法并排比较
//   2. Measure my phone's limit：测这台手机的 GPU 看门狗限时
//   3. 系统信息：内存峰值 / 发热 / 电量
import Foundation
import Metal
import UIKit

// MARK: 系统信息

enum SystemInfo {
    /// 本 App 当前占用的物理内存（MB）：就是系统用来决定「内存超了杀谁」的那个数字
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return ok == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"; case .fair: return "Fair"
        case .serious: return "Serious"; case .critical: return "Critical"; @unknown default: return "Unknown"
        }
    }
    /// 电量百分比；未知返回 -1
    static var batteryPercent: Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let l = UIDevice.current.batteryLevel
        return l < 0 ? -1 : Int((l * 100).rounded())
    }
}

// MARK: Compare methods

struct CompareRow: Identifiable {
    let id: Int
    let name: String
    let accuracy: Double, refAccuracy: Double
    let repairs: Int          // 修复次数（None 没有；Checkpoint-only = 回滚次数；Our method = 影子校验标出的步数）
    let seconds: Double
    var matchesReference: Bool { abs(accuracy - refAccuracy) <= 0.01 }   // 与 CPU 参考相差不超过 1 个百分点
}

extension Trainer {
    /// 三种做法在同一次训练里「同步」往前走：同样的数据、同样的初始权重、同一个打断（只提交一次，三种做法一起遇到）。
    /// 这样比分开三次跑公平，也避开「每次启动只能打断一次」的限制。
    func startCompare() {
        guard !running, !Interruption.usedThisLaunch else { return }
        running = true; comparing = true; compareRows = []; compareNote = ""
        step = 0; elapsed = 0; result = nil; banner = .none
        UIApplication.shared.isIdleTimerDisabled = true
        let (lr, hidden, epochs, seed) = (self.lr, self.hidden, self.epochs, self.seed)
        DispatchQueue.global(qos: .userInitiated).async { self.runCompare(lr: lr, hidden: hidden, epochs: epochs, seed: seed) }
    }

    private func runCompare(lr: Double, hidden: Int, epochs: Int, seed: UInt64) {
        let data = Dataset.shared
        let plan = Plan(seed: seed, hidden: hidden, epochs: epochs, trainCount: data.trainCount)
        let total = plan.totalSteps, at = Trainer.interruptStep(total: total, seed: seed)
        let cpu = CPUNet(H: hidden, lr: Float(lr))
        guard let gpu = GPUNet(hidden: hidden, lr: Float(lr)) else { return }
        DispatchQueue.main.async { self.totalSteps = total }

        let names = ["None (no protection)", "Checkpoint-only", "Our method"]      // 显示时用 tr(name) 翻译
        var w = [Weights](repeating: plan.initial, count: 3)     // 三种做法各自的权重
        var ckpt = w[1]                                          // Checkpoint-only 的存档（每 50 步）
        var repairs = [0, 0, 0], secs = [0.0, 0.0, 0.0]
        let t0 = Date()

        for i in 0..<total {
            autoreleasepool {
                let (xb, yb) = plan.batch(i, data)
                if i == at { Interruption.fire() }               // 同一步、同一次打断
                // 1. None：GPU 给什么就用什么
                var t = Date()
                if let r = gpu.step(w[0], xb, yb) { w[0] = r }
                secs[0] += -t.timeIntervalSinceNow
                // 2. Checkpoint-only：每 50 步存档；只在结果出现 NaN/无穷大 时回滚（抓不到「有限但错」的结果）
                t = Date()
                if i % 50 == 0 { ckpt = w[1] }
                if let r = gpu.step(w[1], xb, yb), !(r.w1.contains { !$0.isFinite } || r.w2.contains { !$0.isFinite }) { w[1] = r }
                else { w[1] = ckpt; repairs[1] += 1 }
                secs[1] += -t.timeIntervalSinceNow
                // 3. Our method：CPU 影子校验 + 重算
                t = Date()
                let out = Trainer.protectedStep(w[2], xb, yb, shadow: cpu.step(w[2], xb, yb), gpu: gpu)
                w[2] = out.w; if out.flagged { repairs[2] += 1 }
                secs[2] += -t.timeIntervalSinceNow
            }
            if i % 5 == 4 { let s = i + 1, e = -t0.timeIntervalSinceNow; DispatchQueue.main.async { self.step = s; self.elapsed = e } }
        }

        // 参考：整个训练只用 CPU 再跑一遍
        DispatchQueue.main.async { self.computingReference = true }
        var rw = plan.initial
        for i in 0..<total { autoreleasepool { let (xb, yb) = plan.batch(i, data); rw = cpu.step(rw, xb, yb) } }
        let refAcc = cpu.accuracy(rw, data)
        let rows = (0..<3).map { CompareRow(id: $0, name: names[$0], accuracy: cpu.accuracy(w[$0], data), refAccuracy: refAcc, repairs: repairs[$0], seconds: secs[$0]) }

        // 说明文字按实测写：没被毁就如实说没被毁
        var note: String
        if rows[0].accuracy < refAcc - 0.10 {
            note = tr("The interruption silently ruined the unprotected run on this phone.")
        } else {
            note = tr("On this phone the interruption did not corrupt training (iOS did report a GPU hang). In our earlier tests it ruined unprotected training on iPhone 16, so all three methods can look the same here.")
        }
        if !Interruption.lastStatus.contains("Hang") { note += " " + tr("(iOS has not reported a hang yet: %@.)", Interruption.lastStatus) }
        // 结果也写进文件，真机自动验证用
        let dump: [String: Any] = ["tag": tag, "seed": seed, "interruptAt": at, "hangStatus": Interruption.lastStatus, "refAccuracy": refAcc, "note": note,
            "rows": rows.map { ["name": $0.name, "accuracy": $0.accuracy, "matchesReference": $0.matchesReference, "repairs": $0.repairs, "seconds": $0.seconds] }]
        try? JSONSerialization.data(withJSONObject: dump).write(to: Store.docs.appendingPathComponent("compare.json"))
        DispatchQueue.main.async {
            self.compareRows = rows; self.compareNote = note
            self.running = false; self.comparing = false; self.computingReference = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: Measure my phone's limit

extension Trainer {
    /// 单个 GPU 任务跑多久会被系统判「卡死」(Hang)？用我们的 Metal 核，循环数从小到大，第一个出错的任务的耗时就是答案。
    /// 副作用：GPU 会被系统重置一次；之后本次启动里再提交的超长任务会被忽略 → 要重启 App 才能再做打断演示。
    func measureLimit() {
        guard !running, !measuring, !Interruption.usedThisLaunch else { return }
        measuring = true; limitText = tr("Measuring… (about 1 minute)")
        Interruption.markUsed()
        DispatchQueue.global(qos: .userInitiated).async {
            let s = LimitMeter.measure()
            DispatchQueue.main.async {
                self.measuring = false
                let dump: [String: Any] = ["tag": self.tag, "limitSeconds": s ?? -1]
                try? JSONSerialization.data(withJSONObject: dump).write(to: Store.docs.appendingPathComponent("limit.json"))
                self.limitText = s.map { tr("Your phone's GPU limit: %.2f s", $0) } ?? tr("Could not measure the limit.")
            }
        }
    }
}

enum LimitMeter {
    /// 返回第一个被系统判 Hang 的 GPU 任务的耗时（秒）；没测到返回 nil
    static func measure() -> Double? {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void spin(device float *o [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]]) {
            float a = float(i);
            for (uint k = 0; k < n; k++) { a = fma(a, 1.0000001f, 1e-7f); }
            o[i] = a;
        }
        """
        guard let lib = try? dev.makeLibrary(source: src, options: nil), let fn = lib.makeFunction(name: "spin"),
              let pso = try? dev.makeComputePipelineState(function: fn), let buf = dev.makeBuffer(length: 4096 * 4) else { return nil }
        // 循环数阶梯（4096 个线程，每组 64 个）：小任务先试，任务越来越长，直到被系统掐掉
        let ladder: [UInt32] = [1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000, 50_000_000,
                                100_000_000, 200_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]
        for loops in ladder {
            guard let cb = q.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
            var n = loops
            enc.setComputePipelineState(pso); enc.setBuffer(buf, offset: 0, index: 0); enc.setBytes(&n, length: 4, index: 1)
            enc.dispatchThreads(MTLSize(width: 4096, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
            let t0 = Date(); cb.commit(); cb.waitUntilCompleted()
            let wall = -t0.timeIntervalSinceNow
            if cb.error != nil { return wall }       // 第一个出错的任务：它的耗时 ≈ 系统的限时
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }
}
