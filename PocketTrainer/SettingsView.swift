// SettingsView.swift —— 设置。每个开关都真的起作用；还没做的功能不放假开关，直接写 "not in this version"
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: ProjectStore
    // 键名和默认值在 PocketTrainerApp 里注册
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("saveDelay") private var saveDelay = 1
    @AppStorage("versionHistory") private var versionHistory = true
    @AppStorage("saveCheckpoints") private var saveCheckpoints = true
    @AppStorage("ckptInterval") private var ckptInterval = 20
    @AppStorage("offerResume") private var offerResume = true
    @AppStorage("verify") private var verify = true
    @AppStorage("theme") private var theme = 0

    var body: some View {
        Form {
            Section("Code editor") {
                Toggle("Auto-save", isOn: $autoSave)
                Picker("Save delay", selection: $saveDelay) { ForEach([1, 2, 5], id: \.self) { Text(tr("%ld s", $0)).tag($0) } }
                Toggle("Version history", isOn: $versionHistory)
            }
            Section(header: Text("Training"), footer: Text("Checkpoints let training continue after a crash. Verifying re-computes every step on the CPU and fixes wrong GPU results.")) {
                Toggle("Save checkpoints", isOn: $saveCheckpoints)
                Picker("Checkpoint interval", selection: $ckptInterval) { ForEach([10, 20, 50, 100], id: \.self) { Text(tr("Every %ld steps", $0)).tag($0) } }
                Toggle("Offer resume on reopen", isOn: $offerResume)
                Toggle("Verify training results", isOn: $verify)
            }
            Section(header: Text("Assistant"), footer: Text("The Assistant tab is an offline, rule-based coach. Ask ChatGPT opens ChatGPT with text you review. PocketTrainer itself never goes online except when you import from GitHub.")) {
                HStack { Text("AI connection"); Spacer(); Text("Not connected").foregroundColor(.secondary) }
                HStack { Text("Voice input"); Spacer(); Text("Not in this version").foregroundColor(.secondary) }
            }
            Section("Storage & appearance") {
                NavigationLink("Manage project storage") { StorageView() }
                Picker("Theme", selection: $theme) { Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2) }
                NavigationLink("About PocketTrainer") { AboutView() }
            }
        }
        .tint(.teal)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) { AskChatGPTButton { ChatContext.settings() }; Button("Done") { dismiss() } } }
    }
}

/// 每个项目占多少空间，可以删除
struct StorageView: View {
    @EnvironmentObject var store: ProjectStore
    var body: some View {
        List {
            ForEach(store.projects) { p in
                HStack { Text(p.name); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(ProjectStore.size(p.name)), countStyle: .file)).foregroundColor(.secondary) }
            }
            .onDelete { idx in idx.map { store.projects[$0].name }.forEach { store.delete($0) } }
        }.navigationTitle("Project storage")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section { HStack { Spacer(); LogoMark(size: 72); Spacer() } }
            Section { Text("PocketTrainer trains a small AI on your phone, offline. It double-checks every training step on the CPU, so a silent GPU failure cannot ruin the result.") }
            Section { Text("Translations are machine-assisted and may contain mistakes.") }
            Section("Open data and models") {
                Text("CIFAR-10 photos (Krizhevsky, 2009)")
                Text("ResNet50 features: torchvision ImageNet weights (BSD-3-Clause)")
                Text("Apple frameworks only: SwiftUI, Charts, Metal, Core ML")
            }
            Section { Text("Version 2 · works offline, no account, no tracking. Internet is used only when you import from GitHub.") }
        }.navigationTitle("About")
    }
}
