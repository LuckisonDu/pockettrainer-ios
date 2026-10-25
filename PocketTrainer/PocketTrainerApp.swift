// PocketTrainerApp.swift —— App 入口
// 另外支持「启动参数」，只给我们自己做真机自动验证用（界面上不出现）：
//   --auto-demo=baseline | protect_on | protect_off | crash | compare | limit | import | search | setup | coreml | dataset | export | opendata | gen    不点屏幕，自动跑一轮，结果写进 Documents/result.json
//   --tag=<名字>   写进结果里，方便核对是哪一次    --seed=<数字>   换一个随机种子
import SwiftUI

/// 真机自动测试 / 截图（带 --auto-demo / --screen / --skip-onboarding 启动）时屏幕常亮：两步之间手机锁屏会拉不到结果、截不到图
let testKeepAwake = CommandLine.arguments.contains { $0.hasPrefix("--auto-demo") || $0.hasPrefix("--screen=") || $0 == "--skip-onboarding" }

@main
struct PocketTrainerApp: App {
    @StateObject private var trainer = Trainer()
    @StateObject private var router = Router()
    @StateObject private var store: ProjectStore

    init() {
        // 设置页各开关的默认值（用户改过就以用户的为准）
        UserDefaults.standard.register(defaults: ["autoSave": true, "saveDelay": 1, "versionHistory": true, "saveCheckpoints": true,
                                                  "ckptInterval": 20, "offerResume": true, "verify": true, "theme": 0])
        _store = StateObject(wrappedValue: ProjectStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(trainer).environmentObject(router).environmentObject(store)
                .onAppear { bootstrap() }
        }
    }

    private func arg(_ key: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--\(key)=") }.map { String($0.dropFirst(key.count + 3)) }
    }

    @MainActor private func bootstrap() {
        if testKeepAwake { UIApplication.shared.isIdleTimerDisabled = true }
        if let t = arg("tag") { trainer.tag = t }
        if let p = arg("pace-ms").flatMap({ Double($0) }) { trainer.paceMs = p }
        if let s = arg("seed").flatMap({ UInt64($0) }) { trainer.seed = s }
        if CommandLine.arguments.contains("--teach-selftest") { DispatchQueue.global().async { TeachSelfTest.run() }; return }
        // 上次没训练完（闪退）：设置里「Offer resume on reopen」开着就问用户；关着（或自动测试带了 --tag）就直接续训
        if let s = Store.loadSession() {
            trainer.currentProject = s.config.project ?? ProjectStore.defaultProject
            if UserDefaults.standard.bool(forKey: "offerResume") && arg("tag") == nil { trainer.pendingResume = s } else { trainer.resumeIfNeeded() }
            return
        }
        // 下面只在带 --auto-demo 启动时才会走到（真机自动验证用）
        guard let mode = arg("auto-demo") else { return }
        try? FileManager.default.removeItem(at: Store.resultURL)
        switch mode {
        case "baseline":    trainer.protect = true;  trainer.interruptArmed = false
        case "protect_on":  trainer.protect = true;  trainer.interruptArmed = true
        case "protect_off": trainer.protect = false; trainer.interruptArmed = true
        case "compare": try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent("compare.json")); trainer.startCompare(); return
        case "import":  try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent("import.json")); ImportModel.autoDemo(url: arg("url") ?? "", store: store); return
        case "export":  AutoDemo.exportCheck(); return
        case "search":  AutoDemo.search(q: arg("q") ?? "mnist", source: arg("source") ?? "github"); return
        case "setup":   AutoDemo.setup(url: arg("url") ?? "", store: store); return
        case "coreml":  AutoDemo.coreml(repo: arg("repo") ?? "apple/coreml-resnet-50", model: arg("model"), store: store); return
        case "dataset": AutoDemo.dataset(repo: arg("repo") ?? "scikit-learn/iris", store: store, trainer: trainer); return
        case "opendata": AutoDemo.openData(id: arg("data") ?? "iris", store: store, trainer: trainer, router: router); return
        case "gen":     AutoDemo.generator(id: arg("data") ?? "mnist", store: store, router: router); return
        case "limit":   try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent("limit.json")); trainer.measureLimit(); return
        case "crash":       trainer.protect = true;  trainer.crashArmed = true
        default: return
        }
        router.path = [.editor(trainer.currentProject)]   // 录屏演示：直接打开训练页，画面上能看到曲线和横幅
        trainer.start()
    }
}
