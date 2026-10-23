// AskChatGPT.swift —— 「Ask ChatGPT」：不接 API、不放密钥。
// 把当前页面的上下文做成一段文字，让用户看过、可以改、写下自己的问题；点「Open in ChatGPT」才复制并打开 chatgpt.com。
// 绝不自动发送，只发文字（不发照片和文件）。
import SwiftUI

/// 每个页面右上角的小按钮
struct AskChatGPTButton: View {
    let context: () -> String
    var labeled = false
    @State private var show = false
    var body: some View {
        Button { show = true } label: {
            if labeled { Label("Ask ChatGPT", systemImage: "bubble.left.and.text.bubble.right").frame(maxWidth: .infinity) }
            else { Image(systemName: "bubble.left.and.text.bubble.right").font(.title3).foregroundColor(.teal) }
        }
        .accessibilityLabel("Ask ChatGPT")
        .sheet(isPresented: $show) { AskChatGPTSheet(context: context()) }
    }
}

struct AskChatGPTSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: String
    @State private var question = ""
    @State private var note = ""
    static let maxURLChars = 1500

    init(context: String, question: String = "") {
        _question = State(initialValue: question)
        let lang = Locale(identifier: "en").localizedString(forIdentifier: Bundle.main.preferredLocalizations.first ?? "en") ?? "English"
        _prompt = State(initialValue: "Please answer in \(lang).\nI am using PocketTrainer, an offline iPhone app that trains a small image classifier and checks every training step on the CPU.\n\n\(context)")
    }

    /// 真正会发出去的全文
    private var fullText: String { prompt + (question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\nMy question: " + question) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review the text below. Nothing is sent until you tap Open in ChatGPT. Only this text is shared, never photos or files.").font(.footnote).foregroundColor(.secondary)
                    Text("My question").font(.subheadline.bold())
                    TextField("Type or speak your question", text: $question, axis: .vertical).lineLimit(2...5)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                    MicButton(text: $question)
                    Text("Prompt (you can edit it)").font(.subheadline.bold())
                    TextEditor(text: $prompt).frame(height: 170).font(.system(size: 12, design: .monospaced)).padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                    DisclosureGroup("What will be sent") { Text(fullText).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.font(.footnote)
                    Button("Open in ChatGPT") { open() }.buttonStyle(TealButtonStyle())
                    if !note.isEmpty { Text(note).font(.footnote).foregroundColor(.secondary) }
                }.padding(16)
            }
            .navigationTitle("Ask ChatGPT").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    /// 先复制到剪贴板，再打开 https://chatgpt.com/?q=…（装了 ChatGPT App 会被它接走）
    private func open() {
        UIPasteboard.general.string = fullText
        var text = fullText
        if text.count > Self.maxURLChars {
            text = String(text.prefix(Self.maxURLChars))
            note = tr("Full text copied. The link carries only the first %ld characters; paste the rest in ChatGPT.", Self.maxURLChars)
        } else { note = tr("Copied to the clipboard.") }
        var c = URLComponents(string: "https://chatgpt.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: text)]
        if let u = c.url { UIApplication.shared.open(u) }
    }
}

/// 各个页面的上下文文字（英文，给 ChatGPT 读）。只含数字和设置，不含照片和文件
enum ChatContext {
    private static func runLines(_ runs: [RunRecord], _ n: Int = 3) -> String {
        runs.prefix(n).map { String(format: "- %@: accuracy %.1f%%, learning rate %.3g, %d hidden units, %d epochs, errors fixed %d, verification %@", $0.project, $0.accuracy * 100, $0.lr, $0.hidden, $0.epochs, $0.fixed, $0.protect ? "on" : "off") }.joined(separator: "\n")
    }
    static func projects(_ store: ProjectStore) -> String {
        "Screen: Projects.\nProjects: " + store.projects.map(\.name).joined(separator: ", ") + "\nLatest runs:\n" + (runLines(RunHistory.all()).isEmpty ? "(none yet)" : runLines(RunHistory.all()))
    }
    static func editor(project: String, file: String, trainer: Trainer) -> String {
        let model = ProjectStore.recipePath(project).map { FileStore.read(project, $0) } ?? ""
        let keys = ["hidden_units", "learning_rate", "epochs", "seed"].compactMap { k in ConfigCode.value(k, in: model).map { "\(k) = \($0)" } }.joined(separator: ", ")
        let out = trainer.currentProject == project ? trainer.log.suffix(8).joined(separator: "\n") : "(no run yet)"
        return "Screen: code editor. Project: \(project). Open file: \(file).\nRecipe settings: \(keys.isEmpty ? "(none)" : keys)\nLast run output:\n\(out)"
    }
    static func files(_ project: String) -> String {
        let root = ProjectStore.dir(project)
        let all = ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).filter { !$0.hasPrefix(".") }.sorted().prefix(60)
        return "Screen: Project files. Project: \(project).\nFiles:\n" + all.joined(separator: "\n")
    }
    static func settings() -> String {
        let d = UserDefaults.standard
        return "Screen: Settings.\nAuto-save: \(d.bool(forKey: "autoSave")), save delay: \(d.integer(forKey: "saveDelay")) s, version history: \(d.bool(forKey: "versionHistory")),\nsave checkpoints: \(d.bool(forKey: "saveCheckpoints")), checkpoint interval: every \(d.integer(forKey: "ckptInterval")) steps, offer resume: \(d.bool(forKey: "offerResume")), verify training results: \(d.bool(forKey: "verify"))."
    }
    static func environment(_ env: EnvChecker, project: String) -> String {
        "Screen: Environment (project check). Project: \(project). Status: \(env.statusText).\nPackages: " + env.packages.map { "\($0.name) needs \($0.required) have \($0.have) (\($0.status))" }.joined(separator: "; ") + "\nLog:\n" + env.log.suffix(15).joined(separator: "\n")
    }
    static func notes(project: String, runs: [RunRecord]) -> String {
        "Screen: Notes. Project: \(project).\nKey takeaways:\n" + Advice.takeaways(runs: runs, project: project).map { "- \($0.text)" }.joined(separator: "\n") + "\nMy notes: " + NoteStore.all(project).prefix(5).map(\.title).joined(separator: " | ")
    }
    static func assistant(_ runs: [RunRecord]) -> String {
        "Screen: Assistant (offline coach).\nLast runs:\n" + (runLines(runs).isEmpty ? "(none yet)" : runLines(runs)) + "\nCoach tips:\n" + Advice.coach(runs: runs).map { "- \($0)" }.joined(separator: "\n")
    }
    static func lab(_ t: Trainer) -> String {
        let rows = t.compareRows.map { String(format: "- %@: accuracy %.1f%%, repairs %d, %.1f s", $0.name, $0.accuracy * 100, $0.repairs, $0.seconds) }.joined(separator: "\n")
        return "Screen: Protection lab.\nCompare methods:\n\(rows.isEmpty ? "(not run yet)" : rows)\n\(t.compareNote)\nGPU limit: \(t.limitText.isEmpty ? "(not measured)" : t.limitText)"
    }
    static func file(project: String, file: String, text: String) -> String {
        "Screen: code editor. Project: \(project). File: \(file).\nFile content (first 3000 characters):\n" + String(text.prefix(3000))
    }
    static func note(source: String?, text: String) -> String { "Screen: Add note. Source: \(source ?? "Notes page").\nNote so far: \(text)" }
}
