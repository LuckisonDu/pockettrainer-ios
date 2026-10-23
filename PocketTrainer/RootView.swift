// RootView.swift —— 底部 4 个 Tab（Projects / Environment / Notes / Assistant）+ 页面跳转 + 首页
import SwiftUI

enum AppTab: Hashable { case projects, environment, notes, assistant }
enum Route: Hashable { case files(String), editor(String), lab, coreml(String), dataset(String), modelfiles(String) }

/// 记录「现在在哪个 Tab、哪一页」。启动参数 --tab= / --screen= 只用来给真机截图（直接打开某一页）
final class Router: ObservableObject {
    @Published var tab = AppTab.projects
    @Published var path: [Route] = []
    @Published var showSettings = false
    @Published var showAddNote = false
    @Published var showAdd = false           // 首页「+」弹窗
    @Published var openExplain = false       // 编辑器一打开就弹「Ask ChatGPT」（截图用）
    @Published var openSearch = false        // 弹窗一打开就进「Find projects」（截图用）
    var projectArg: String?                  // --project=<名字>：截图时指定项目
    @Published var setupURL: String?         // 搜索页点了「Download & set up」：Environment 页收到后开始
    @Published var openFile: String?        // 在文件树里点了某个文件：编辑器打开它

    init() {
        func arg(_ k: String) -> String? { CommandLine.arguments.first { $0.hasPrefix("--\(k)=") }.map { String($0.dropFirst(k.count + 3)) } }
        switch arg("tab") {
        case "environment": tab = .environment
        case "notes": tab = .notes
        case "assistant": tab = .assistant
        default: break
        }
        let p = arg("project") ?? ProjectStore.defaultProject
        projectArg = arg("project")
        switch arg("screen") {
        case "find": showAdd = true; openSearch = true
        case "ask": path = [.editor(p)]; openExplain = true
        case "coreml": path = [.editor(p), .coreml(p)]
        case "dataset": path = [.editor(p), .dataset(p)]
        case "modelfiles": path = [.editor(p), .modelfiles(p)]
        case "files": path = [.editor(p), .files(p)]
        case "editor": path = [.editor(p)]
        case "lab": path = [.editor(p), .lab]
        case "settings": showSettings = true
        case "addnote": path = [.editor(p)]; showAddNote = true
        default: break
        }
    }
}

struct RootView: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var trainer: Trainer
    @AppStorage("theme") private var theme = 0      // 0 跟随系统 1 浅色 2 深色
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded") && !CommandLine.arguments.contains { $0.hasPrefix("--auto-demo") || $0 == "--skip-onboarding" || $0.hasPrefix("--tab=") || $0.hasPrefix("--screen=") }

    var body: some View {
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: Route.self) { r in
                        switch r {
                        case .files(let p): FilesView(project: p)
                        case .editor(let p): EditorView(project: p)
                        case .lab: ProtectionLabView()
                        case .coreml(let p): CoreMLView(project: p)
                        case .dataset(let p): TabularView(project: p)
                        case .modelfiles(let p): ModelFilesView(project: p)
                        }
                    }
            }
            .tabItem { Label("Projects", systemImage: "square.stack.3d.up") }.tag(AppTab.projects)
            EnvironmentView().tabItem { Label("Environment", systemImage: "terminal") }.tag(AppTab.environment)
            NotesView().tabItem { Label("Notes", systemImage: "doc.text") }.tag(AppTab.notes)
            CoachView().tabItem { Label("Assistant", systemImage: "sparkles") }.tag(AppTab.assistant)
        }
        .tint(.teal)
        .preferredColorScheme(theme == 1 ? .light : theme == 2 ? .dark : nil)
        .sheet(isPresented: $router.showSettings) { NavigationStack { SettingsView() } }
        .fullScreenCover(isPresented: $showOnboarding) { OnboardingView(shown: $showOnboarding) }
        .alert("Resume training?", isPresented: Binding(get: { trainer.pendingResume != nil }, set: { _ in })) {
            Button("Resume") { trainer.pendingResume = nil; trainer.resumeIfNeeded() }
            Button("Discard", role: .destructive) { trainer.pendingResume = nil; Store.clearSession() }
        } message: { Text("The last training did not finish. It can continue from its saved checkpoint.") }
    }
}

struct GearButton: View {
    @EnvironmentObject var router: Router
    var body: some View {
        Button { router.showSettings = true } label: { Image(systemName: "gearshape").font(.title3).foregroundColor(.secondary) }
    }
}

// MARK: 首页

struct HomeView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var trainer: Trainer
    @EnvironmentObject var router: Router
    @State private var runs = RunHistory.all()

    private var current: String { store.projects.first?.name ?? ProjectStore.defaultProject }

    /// 「Checkpoint · Step N」：优先看没训完的存档（真实的 pt_ckpt.bin），否则看项目里最新的检查点文件
    private var checkpointText: String {
        if let s = Store.loadSession(), let (_, step) = Store.loadCheckpoint(hidden: s.config.hidden) { return tr("Checkpoint · Step %ld (unfinished)", step) }
        if let c = ProjectStore.latestCheckpoint(current) { return tr("Checkpoint · Step %ld", c.step) }
        return tr("No checkpoint yet")
    }
    private var hasUnfinished: Bool { Store.loadSession() != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { LogoView(); Spacer(); AskChatGPTButton { ChatContext.projects(store) }; GearButton() }
                Card {
                    Text("CONTINUE PROJECT").font(.caption.bold()).foregroundColor(.secondary)
                    Text(current).font(.title2.bold())
                    Text(checkpointText).font(.subheadline).foregroundColor(.secondary)
                    Button(hasUnfinished ? tr("Resume project") : tr("Open project")) {
                        if hasUnfinished { trainer.resumeIfNeeded() }
                        store.touch(current); router.path = [.editor(current)]
                    }.buttonStyle(TealButtonStyle())
                }
                HStack { SectionTitle(text: "Your projects"); Spacer()
                    Button { router.showAdd = true } label: { Image(systemName: "plus").font(.headline).foregroundColor(.white).frame(width: 30, height: 30).background(Circle().fill(Color.teal)) } }
                Card(padding: 4) {
                    ForEach(store.projects) { p in
                        Button { store.touch(p.name); router.path = [.editor(p.name)] } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.headline).foregroundColor(.primary)
                                    Text(tr("Last opened · %@", p.lastOpened?.friendly ?? tr("never"))).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }.padding(10)
                        }
                        if p != store.projects.last { Divider() }
                    }
                }
                SectionTitle(text: "Latest runs")
                Card(padding: 4) {
                    if runs.isEmpty { Text("No runs yet. Open a project and press Run.").font(.subheadline).foregroundColor(.secondary).padding(10) }
                    ForEach(runs.prefix(3)) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.project).font(.subheadline.bold())
                            Text(r.summary + " · " + r.date.friendly).font(.caption).foregroundColor(.secondary)
                        }.padding(10)
                        if r.id != runs.prefix(3).last?.id { Divider() }
                    }
                }
            }.padding(16)
        }
        .background(Color.pageBackground)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: .runHistoryChanged)) { _ in runs = RunHistory.all() }
        .onAppear { runs = RunHistory.all(); store.reload() }
        .sheet(isPresented: $router.showAdd) { AddProjectSheet() }
    }
}

struct AddProjectSheet: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var router: Router
    @State private var goSearch = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { SearchView() } label: {
                    Label("Find projects", systemImage: "magnifyingglass").font(.headline).foregroundColor(.teal)
                }
                NavigationLink { ImportView() } label: {
                    Label("Import from GitHub", systemImage: "arrow.down.circle").font(.headline).foregroundColor(.teal)
                }
                Section("New from a template") {
                    ForEach(Template.all) { t in
                        Button { store.create(t, name: t.title); dismiss() } label: {
                            VStack(alignment: .leading) { Text(t.title).font(.headline); Text(tr(t.blurb)).font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $goSearch) { SearchView() }
            .onAppear { if router.openSearch { router.openSearch = false; goSearch = true } }
            .navigationTitle("New project").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }.presentationDetents([.large])
    }
}
