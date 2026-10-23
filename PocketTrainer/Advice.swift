// Advice.swift —— 离线「教练」：只看最近几次运行的数字，用简单的 if 规则给建议（没有联网、没有大模型）
// 文字都走 tr()（多语言），英文原文是翻译表里的键。
import Foundation

enum Advice {
    /// Notes 页的 Key takeaways：(文字, 小标签)
    static func takeaways(runs: [RunRecord], project: String) -> [(text: String, tag: String)] {
        var out: [(String, String)] = []
        if let a = runs.first, let b = runs.dropFirst().first(where: { $0.lr != runs.first!.lr }) {
            out.append((tr("Learning rate %.3g gave %.1f%%, %.3g gave %.1f%% — it controls update size", a.lr, a.accuracy * 100, b.lr, b.accuracy * 100), "model.py"))
        } else { out.append((tr("Learning rate controls update size"), "model.py")) }
        if let a = runs.first {
            let gap = a.lastValLoss - a.lastLoss
            out.append((tr(gap > 0.25 ? "Compare train loss (%.2f) and validation loss (%.2f) — big gap: memorising" : "Compare train loss (%.2f) and validation loss (%.2f)", a.lastLoss, a.lastValLoss), "Last run"))
        } else { out.append((tr("Compare train loss and validation loss"), "Run")) }
        if let c = ProjectStore.latestCheckpoint(project) { out.append((tr("Checkpoint saved at step %ld: checkpoints let you resume later", c.step), "train.py")) }
        else { out.append((tr("Checkpoints let you resume later"), "train.py")) }
        return out
    }

    /// Assistant 页的建议（友好语气）
    static func coach(runs: [RunRecord]) -> [String] {
        guard let r = runs.first else { return [tr("Run a project first. Then I can look at your numbers and suggest what to try next.")] }
        var tips: [String] = []
        if !r.protect && r.accuracy < r.refAccuracy - 0.10 {
            tips.append(tr("Your accuracy is %.0f%% but the CPU reference got %.0f%%. Verification was off, so a silent GPU error may have ruined training. Turn on \"Verify training results\" in Settings.", r.accuracy * 100, r.refAccuracy * 100))
        }
        if r.fixed > 0 { tips.append(tr("Verification found and fixed wrong GPU steps: %ld. Without it this run could have been silently wrong.", r.fixed)) }
        if r.lastLoss >= r.firstLoss * 0.9 && r.firstLoss > 0 {
            tips.append(tr("The loss barely went down. Try a bigger learning rate, for example %@.", String(format: "%.3g", r.lr * 2)))
        }
        if r.lastValLoss - r.lastLoss > 0.25 {
            tips.append(tr("Validation loss is higher than training loss by %.2f. The model may be memorising the photos: try fewer epochs or fewer hidden units.", r.lastValLoss - r.lastLoss))
        }
        if r.accuracy < 0.8 && r.epochs <= 3 { tips.append(tr("Only %ld epochs so far — try more epochs so the model sees the photos more times.", r.epochs)) }
        if r.lr >= 0.15 && r.accuracy < 0.8 { tips.append(tr("A learning rate of %.3g is large. If the loss bounces up and down, try 0.05.", r.lr)) }
        if let p = runs.dropFirst().first, p.lr != r.lr {
            tips.append(tr("Compared with your previous run: learning rate %.3g → %.3g changed accuracy from %.1f%% to %.1f%%.", p.lr, r.lr, p.accuracy * 100, r.accuracy * 100))
        }
        if tips.isEmpty { tips.append(tr("This run looks healthy. Change one number at a time (for example the learning rate) and compare the curves.")) }
        return tips
    }
}
