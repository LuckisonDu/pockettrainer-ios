// EnvironmentView.swift —— Environment：真的检查项目包（清单 / 版本 / 数据校验 / 3 步试训练），不是动画
import SwiftUI

struct EnvironmentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var trainer: Trainer
    @ObservedObject private var env = EnvChecker.shared
    @EnvironmentObject var router: Router
    @State private var project = CommandLine.arguments.first { $0.hasPrefix("--project=") }.map { String($0.dropFirst(10)) } ?? ProjectStore.defaultProject
    @State private var showDetails = false
    @State private var showImport = false

    /// 搜索页点了「Download & set up」：开始下载并分析
    private func startPending() {
        guard let u = router.setupURL else { return }
        router.setupURL = nil
        env.setup(url: u, store: store) { name in if let name { project = name } }
    }

    private let stepNames = ["Analyze", "Resolve", "Install", "Test"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScreenHeader(title: "Environment") { AskChatGPTButton { ChatContext.environment(env, project: project) }; GearButton() }
                    HStack {
                        Text("Project").font(.caption).foregroundColor(.secondary)
                        Picker("Project", selection: $project) { ForEach(store.projects) { Text($0.name).tag($0.name) } }.pickerStyle(.menu).tint(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 10).background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
                    setupCard
                    packagesCard
                    conflictCard
                    logCard
                    HStack {
                        Button { env.check(project: project) } label: { Label("Check again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }.buttonStyle(.bordered).tint(.teal).disabled(env.busy)
                        Button { showDetails = true } label: { Label("View details", systemImage: "list.bullet").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.teal)
                    }
                    downloadCard
                }.padding(16)
            }
            .background(Color.pageBackground)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { startPending(); if env.passed == nil && !env.busy { env.check(project: project) } }
            .onChange(of: router.setupURL) { _ in startPending() }
            .onChange(of: project) { _ in env.check(project: project) }
            .sheet(isPresented: $showImport) { NavigationStack { ImportView() } }
            .sheet(isPresented: $showDetails) {
                NavigationStack { ScrollView { Text(env.manifestText).font(.system(size: 12, design: .monospaced)).padding() }
                    .navigationTitle("manifest.json").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { showDetails = false } } }
            }
        }
    }

    private var setupCard: some View {
        Card {
            Text("Project check").font(.subheadline.bold())
            HStack(alignment: .top) {
                ForEach(0..<4, id: \.self) { i in
                    VStack(spacing: 4) {
                        Image(systemName: env.passed == false && i == env.phase ? "xmark.circle.fill" : (i < env.phase ? "checkmark.circle.fill" : (i == env.phase ? "\(i + 1).circle.fill" : "\(i + 1).circle")))
                            .foregroundColor(env.passed == false && i == env.phase ? .red : (i <= env.phase ? .teal : .secondary)).font(.title3)
                        Text(LocalizedStringKey(stepNames[i])).font(.caption2)
                    }.frame(maxWidth: .infinity)
                }
            }
            HStack { Text(env.statusText).font(.caption); Spacer(); if env.busy { Text("\(Int((Double(env.phase) + env.progress) / 4 * 100))%").font(.caption.bold()) } }
            ProgressView(value: min(1, (Double(env.phase) + env.progress) / 4)).tint(env.passed == false ? .red : .teal)
        }
    }

    private var packagesCard: some View {
        Card {
            Text("Required packages").font(.subheadline.bold())
            if env.packages.isEmpty { Text("Waiting for the manifest…").font(.caption).foregroundColor(.secondary) }
            ForEach(env.packages) { p in
                let bad = p.status == "Conflict" || p.status == "Not available on iOS" || p.status == "Not available"
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "shippingbox").foregroundColor(.secondary)
                        Text(p.name).font(.subheadline)
                        Spacer()
                        Text(tr("needs %@ · have %@", p.required, p.have)).font(.caption).foregroundColor(.secondary)
                        Text(tr(p.status)).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill((bad ? Color.red : Color.teal).opacity(0.15))).foregroundColor(bad ? .red : .teal)
                    }
                    if bad && !p.reason.isEmpty { Text(tr(p.reason)).font(.caption2).foregroundColor(.secondary).padding(.leading, 26) }
                }
            }
        }
    }

    private var conflictCard: some View {
        Card {
            Text("Conflict resolution").font(.subheadline.bold())
            if let c = env.conflict {
                Label(c, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundColor(.orange)
                Text("Only plain-text recipe packs can be added. This app cannot install other versions of its packages.").font(.caption).foregroundColor(.secondary)
            } else if env.packages.isEmpty {
                Text("—").foregroundColor(.secondary)
            } else {
                Label("No conflicts: every package the project needs is compatible with this app.", systemImage: "checkmark.circle.fill").font(.footnote).foregroundColor(.teal)
            }
        }
    }

    private var logCard: some View {
        Card {
            Text("Live log").font(.subheadline.bold())
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(env.log.enumerated()), id: \.offset) { _, l in Text(l) }
            }.font(.system(size: 10.5, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 导入入口（取代以前的「下载项目包」）：和首页「+」里的是同一个界面
    private var downloadCard: some View {
        Card {
            Text("Import from GitHub").font(.subheadline.bold())
            Text("Download open-source text files, then read, edit and (for recipes) train. PocketTrainer goes online only while importing.").font(.caption).foregroundColor(.secondary)
            Button("Import from GitHub") { showImport = true }.buttonStyle(TealButtonStyle())
        }
    }
}
