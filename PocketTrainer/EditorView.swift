// EditorView.swift —— 代码编辑器 + Parameters + Run + Output + Loss 曲线
import SwiftUI
import Charts

/// 读写项目里的文件；保存时把旧版本留一份到 .history（最多 10 份）
enum FileStore {
    static func read(_ project: String, _ rel: String) -> String { (try? String(contentsOf: ProjectStore.dir(project).appendingPathComponent(rel), encoding: .utf8)) ?? "" }

    static func write(_ project: String, _ rel: String, _ text: String) {
        let url = ProjectStore.dir(project).appendingPathComponent(rel)
        let old = read(project, rel)
        guard old != text else { return }
        if UserDefaults.standard.bool(forKey: "versionHistory"), !old.isEmpty {
            let h = historyDir(project, rel)
            try? FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
            try? old.write(to: h.appendingPathComponent(String(Int(Date().timeIntervalSince1970))), atomically: true, encoding: .utf8)
            for f in versions(project, rel).dropFirst(10) { try? FileManager.default.removeItem(at: h.appendingPathComponent(f)) }
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func historyDir(_ project: String, _ rel: String) -> URL {
        ProjectStore.dir(project).appendingPathComponent(".history/" + rel.replacingOccurrences(of: "/", with: "_"))
    }
    /// 旧版本（时间戳文件名，新的在前）
    static func versions(_ project: String, _ rel: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: historyDir(project, rel).path)) ?? []).sorted(by: >)
    }
}

struct EditorView: View {
    let project: String
    @EnvironmentObject var trainer: Trainer
    @EnvironmentObject var router: Router
    @EnvironmentObject var store: ProjectStore
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("saveDelay") private var saveDelay = 1

    @State private var tabs: [String] = []
    @State private var current = "code/model.py"
    @State private var recipe: String?          // 配方文件（model.py）；没有 = 这个项目只能读和改，不能跑
    @State private var showMap = false
    @State private var showExplain = false
    @State private var text = ""
    @State private var line = 1
    @State private var lr = ""
    @State private var hidden = ""
    @State private var epochs = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var error = ""
    @State private var bigChart = false
    @State private var showHistory = false
    @State private var showTeach = false

    private var isModel: Bool { current == recipe }
    private var canRun: Bool { kind == "photos" || recipe != nil }
    private var kind: String { store.projects.first { $0.name == project }?.kind ?? "cifar" }
    private var mine: Bool { trainer.currentProject == project }       // Output 是不是这个项目的

    /// 录屏演示（--auto-demo 启动）：训练时页面自动滚到底，让曲线和结果横幅都在画面里
    private var demoMode: Bool { CommandLine.arguments.contains { $0.hasPrefix("--auto-demo=") } }
    var body: some View {
        ScrollViewReader { demoProxy in
            editorBody
                .onChange(of: trainer.step) { _ in if demoMode { withAnimation { demoProxy.scrollTo("demoEnd", anchor: .bottom) } } }
                .onChange(of: trainer.running) { _ in if demoMode { withAnimation { demoProxy.scrollTo("demoEnd", anchor: .bottom) } } }
        }
    }

    private var editorBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                tabBar
                CodeBox(text: $text, line: $line)
                Text("PocketTrainer runs your settings with its built-in trainer (not full Python).").font(.caption).foregroundColor(.secondary)
                if isModel && kind != "photos" { paramsCard }
                Button(kind == "photos" ? tr("Open photo teacher") : (trainer.running ? tr("Running…") : tr("Run"))) { run() }
                    .buttonStyle(TealButtonStyle()).disabled(trainer.running || !canRun)
                if !canRun {
                    Text("This project can be read and edited. PocketTrainer can only run recipes with its built-in trainer (not full Python or PyTorch).").font(.footnote).foregroundColor(.secondary)
                }
                if kind == "import" {
                    Button { showMap = true } label: { Label("Map to recipe", systemImage: "arrow.triangle.branch").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(.teal)
                }
                if !error.isEmpty { Text(error).font(.footnote).foregroundColor(.red) }
                if kind == "import" { ProjectToolsCard(project: project) }
                if canRun && kind != "photos" { outputCard; lossCard.id("demoEnd"); ExportCard(project: project, isPhotoProject: kind == "cifar") }
                NavigationLink(value: Route.lab) {
                    Label("Protection lab", systemImage: "shield.lefthalf.filled").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).tint(.teal)
            }.padding(14)
        }
        .background(Color.pageBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { LogoView() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                AskChatGPTButton { ChatContext.editor(project: project, file: current, trainer: trainer) }
                Button { router.showAddNote = true } label: { Image(systemName: "square.and.pencil") }
                Button { router.path.append(.files(project)) } label: { Image(systemName: "folder.badge.plus") }
                Menu { Button("Version history") { showHistory = true }; Button("Explain this file") { showExplain = true } } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            store.touch(project)
            refreshRecipe()
            if router.openExplain { router.openExplain = false; showExplain = true }
            if let f = router.openFile { if !tabs.contains(f) { tabs.append(f) }; current = f; router.openFile = nil }
            load()
        }
        .onDisappear { save() }
        .onChange(of: current) { _ in save(); load() }
        .onChange(of: text) { _ in textChanged() }
        .onChange(of: lr) { _ in paramChanged("learning_rate", lr) }
        .onChange(of: hidden) { _ in paramChanged("hidden_units", hidden) }
        .onChange(of: epochs) { _ in paramChanged("epochs", epochs) }
        .sheet(isPresented: $router.showAddNote) { AddNoteSheet(project: project, file: current, line: line, text: $text) }
        .sheet(isPresented: $showHistory) { HistorySheet(project: project, file: current, text: $text) }
        .sheet(isPresented: $bigChart) { LossChart(points: trainer.lossPoints).frame(height: 320).padding().presentationDetents([.medium]) }
        .sheet(isPresented: $showTeach) { TeachView() }
        .sheet(isPresented: $showExplain) { AskChatGPTSheet(context: ChatContext.file(project: project, file: current, text: text), question: "Please explain this file in simple words for a high-school student. What does each part do?") }
        .sheet(isPresented: $showMap, onDismiss: { refreshRecipe(); load() }) { MapRecipeSheet(project: project) }
    }

    // MARK: 各部分

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.self) { t in
                    Button { current = t } label: {
                        Text(t.hasSuffix("learning-notes.md") ? "notes.md" : (t as NSString).lastPathComponent).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(t == current ? Color.teal.opacity(0.18) : Color.cardBackground))
                            .foregroundColor(t == current ? .teal : .primary)
                    }
                }
            }
        }
    }

    private var paramsCard: some View {
        Card {
            Text("Parameters").font(.headline)
            HStack(spacing: 10) {
                field("Learning rate", $lr, .decimalPad); field("Hidden units", $hidden, .numberPad); field("Epochs", $epochs, .numberPad)
            }
        }
    }

    private func field(_ title: LocalizedStringKey, _ value: Binding<String>, _ kb: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField("", text: value).keyboardType(kb).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
        }
    }

    private var outputCard: some View {
        Card {
            HStack { Text("Output").font(.headline); Spacer() }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        let lines = mine ? trainer.log : []
                        if lines.isEmpty { Text("Press Run to start training.").foregroundColor(.secondary) }
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in Text(l).id(i) }
                    }.font(.system(size: 11.5, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .onChange(of: trainer.log.count) { n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            if mine && trainer.running { ProgressView(value: Double(trainer.step), total: Double(max(trainer.totalSteps, 1))) }
        }
    }

    private var lossCard: some View {
        Card {
            HStack { Text("Loss (smaller is better)").font(.headline); Spacer()
                Button { bigChart = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") } }
            LossChart(points: mine ? trainer.lossPoints : []).frame(height: 150)
        }
    }

    // MARK: 动作

    /// 重新找配方文件，并整理顶部的文件标签
    private func refreshRecipe() {
        recipe = ProjectStore.recipePath(project)
        let root = ProjectStore.dir(project)
        let defaults = [recipe ?? "code/model.py", "code/train.py", "notes/learning-notes.md", "README.md"]
        var t = defaults.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        if t.isEmpty, let any = ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).filter({ $0.hasSuffix(".py") || $0.hasSuffix(".md") }).sorted().first { t = [any] }
        for x in tabs where !t.contains(x) && FileManager.default.fileExists(atPath: root.appendingPathComponent(x).path) { t.append(x) }
        tabs = Array(t.prefix(8))
        if !tabs.contains(current) { current = tabs.first ?? current }
    }

    private func load() {
        text = FileStore.read(project, current)
        syncFields()
    }
    private func save() { saveTask?.cancel(); FileStore.write(project, current, text) }

    /// 文字改了：同步参数框；过 N 秒自动保存
    private func textChanged() {
        syncFields()
        guard autoSave else { return }
        saveTask?.cancel()
        let (p, f, t) = (project, current, text)
        saveTask = Task { try? await Task.sleep(nanoseconds: UInt64(saveDelay) * 1_000_000_000); if !Task.isCancelled { FileStore.write(p, f, t) } }
    }
    private func syncFields() {
        guard isModel else { return }
        if let v = ConfigCode.value("learning_rate", in: text), v != lr { lr = v }
        if let v = ConfigCode.value("hidden_units", in: text), v != hidden { hidden = v }
        if let v = ConfigCode.value("epochs", in: text), v != epochs { epochs = v }
    }
    /// 参数框改了：把代码里对应那行改掉
    private func paramChanged(_ key: String, _ v: String) {
        guard isModel, !v.isEmpty, ConfigCode.value(key, in: text) != v else { return }
        text = ConfigCode.set(key, v, in: text)
    }

    private func run() {
        save()
        if kind == "photos" { showTeach = true; return }
        guard let recipe else { return }
        let model = FileStore.read(project, recipe)
        guard let l = ConfigCode.value("learning_rate", in: model).flatMap(Double.init), (0.001...1.0).contains(l) else { error = tr("learning_rate must be a number from 0.001 to 1."); return }
        guard let h = ConfigCode.value("hidden_units", in: model).flatMap(Int.init), (8...1024).contains(h) else { error = tr("hidden_units must be a whole number from 8 to 1024."); return }
        guard let e = ConfigCode.value("epochs", in: model).flatMap(Int.init), (1...300).contains(e) else { error = tr("epochs must be a whole number from 1 to 300."); return }
        error = ""
        trainer.lr = l; trainer.hidden = h; trainer.epochs = e
        trainer.seed = ConfigCode.value("seed", in: model).flatMap(UInt64.init) ?? 1
        trainer.protect = UserDefaults.standard.bool(forKey: "verify")       // 设置里的「Verify training results」
        if TabularTools.config(project: project) != nil {                    // 表格项目：用表格数据训练
            do { trainer.dataset = try TabularTools.buildDataset(project: project).0 } catch let e { error = e.localizedDescription; return }
        } else { trainer.dataset = Dataset.shared }
        trainer.currentProject = project
        trainer.start()
        trainer.interruptArmed = false; trainer.crashArmed = false             // 打断/闪退演示只对这一次 Run 有效
    }
}

/// train（蓝）/ val（青）两条损失曲线
struct LossChart: View {
    let points: [LossPoint]
    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Step", p.step), y: .value("Loss", p.train), series: .value("s", "Train loss")).foregroundStyle(by: .value("Line", "Train loss"))
                LineMark(x: .value("Step", p.step), y: .value("Loss", p.val), series: .value("s", "Val loss")).foregroundStyle(by: .value("Line", "Val loss"))
            }
        }
        .chartForegroundStyleScale(["Train loss": Color.blue, "Val loss": Color.teal])
        .chartLegend(position: .top, alignment: .trailing)
        .chartXAxisLabel("Step")
    }
}

/// 旧版本列表，可以恢复
struct HistorySheet: View {
    let project: String, file: String
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            let v = FileStore.versions(project, file)
            List {
                if v.isEmpty { Text("No older versions yet. A copy is kept each time you save a change.").foregroundColor(.secondary) }
                ForEach(v, id: \.self) { ts in
                    Button { text = (try? String(contentsOf: FileStore.historyDir(project, file).appendingPathComponent(ts), encoding: .utf8)) ?? text; dismiss() } label: {
                        Text(Date(timeIntervalSince1970: Double(ts) ?? 0).friendly + "  ·  " + tr("Restore"))
                    }
                }
            }
            .navigationTitle("Version history").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }.presentationDetents([.medium])
    }
}
