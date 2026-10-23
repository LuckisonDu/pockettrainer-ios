// NotesView.swift —— Notes 页（Key takeaways / Learning plan / My notes）和「Add note」底部弹窗
import SwiftUI

/// 一条笔记 = 项目 notes/ 文件夹里的一个 .md 文件
struct NoteItem: Identifiable { let id: String; let title: String; let body: String; let date: Date }

enum NoteStore {
    static func all(_ project: String) -> [NoteItem] {
        let dir = ProjectStore.dir(project).appendingPathComponent("notes")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("note_") && $0.hasSuffix(".md") }.sorted(by: >)
        return names.compactMap { n in
            guard let t = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) else { return nil }
            let lines = t.components(separatedBy: "\n")
            let date = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.modificationDate] as? Date) ?? Date()
            return NoteItem(id: n, title: lines.first ?? "", body: lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces), date: date)
        }
    }
    static func add(_ project: String, text: String, source: String?) {
        let dir = ProjectStore.dir(project).appendingPathComponent("notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = text + (source.map { "\n\nSource: \($0)" } ?? "")
        try? body.write(to: dir.appendingPathComponent("note_\(Int(Date().timeIntervalSince1970)).md"), atomically: true, encoding: .utf8)
    }
    static func delete(_ project: String, id: String) { try? FileManager.default.removeItem(at: ProjectStore.dir(project).appendingPathComponent("notes/" + id)) }
}

struct NotesView: View {
    @EnvironmentObject var trainer: Trainer
    @EnvironmentObject var store: ProjectStore
    @State private var runs = RunHistory.all()
    @State private var notes: [NoteItem] = []
    @State private var checks: [Bool] = [false, false, false]
    @State private var showAdd = false
    private var project: String { trainer.currentProject }

    private var plan: [(String, String)] {
        let lr = runs.first.map { String(format: "%.3g", $0.lr / 2) } ?? "0.025"
        return [(tr("Review the last run"), tr("%ld min", 5)), (tr("Test learning rate %@", lr), tr("%ld min", 10)), (tr("Compare results and write a note"), tr("%ld min", 5))]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScreenHeader(title: "Notes") {
                        AskChatGPTButton { ChatContext.notes(project: project, runs: runs) }
                        GearButton()
                        Button { showAdd = true } label: { Image(systemName: "plus").font(.headline).foregroundColor(.white).frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Color.teal)) }
                    }
                    Label(project, systemImage: "folder").font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cardBackground))
                    SectionTitle(text: "Key takeaways")
                    Card(padding: 6) {
                        let t = Advice.takeaways(runs: runs, project: project)
                        ForEach(Array(t.enumerated()), id: \.offset) { i, x in
                            HStack(alignment: .top) {
                                Text("\(i + 1)").font(.caption.bold()).frame(width: 22, height: 22).background(Circle().stroke(Color.secondary.opacity(0.4)))
                                Text(x.text).font(.subheadline)
                                Spacer()
                                Text(tr(x.tag)).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.teal.opacity(0.15))).foregroundColor(.teal)
                            }.padding(8)
                        }
                    }
                    Text("Made from your last runs by simple rules, on this phone.").font(.caption).foregroundColor(.secondary)
                    SectionTitle(text: "Learning plan")
                    Card {
                        ForEach(Array(plan.enumerated()), id: \.offset) { i, p in
                            Button { checks[i].toggle(); UserDefaults.standard.set(checks, forKey: "plan_" + project) } label: {
                                HStack { Image(systemName: checks[i] ? "checkmark.square.fill" : "square").foregroundColor(.teal)
                                    Text(p.0).foregroundColor(.primary); Spacer(); Text(p.1).font(.caption).foregroundColor(.secondary) }
                            }
                        }
                        ProgressView(value: Double(checks.filter { $0 }.count), total: 3).tint(.teal)
                        Text(tr("%ld of 3 completed", checks.filter { $0 }.count)).font(.caption).foregroundColor(.secondary)
                    }
                    SectionTitle(text: "My notes")
                    Card(padding: 6) {
                        if notes.isEmpty { Text("No notes yet. Tap + to add one.").font(.subheadline).foregroundColor(.secondary).padding(8) }
                        ForEach(notes) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.title).font(.subheadline.bold())
                                if !n.body.isEmpty { Text(n.body).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                                Text(n.date.friendly).font(.caption2).foregroundColor(.secondary)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu { Button("Delete", role: .destructive) { NoteStore.delete(project, id: n.id); refresh() } }
                        }
                    }
                }.padding(16)
            }
            .background(Color.pageBackground)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .runHistoryChanged)) { _ in refresh() }
            .sheet(isPresented: $showAdd, onDismiss: refresh) { AddNoteSheet(project: project, file: nil, line: 0, text: .constant("")) }
        }
    }

    private func refresh() {
        runs = RunHistory.all().filter { $0.project == project }
        notes = NoteStore.all(project)
        checks = (UserDefaults.standard.array(forKey: "plan_" + project) as? [Bool]) ?? [false, false, false]
        if checks.count != 3 { checks = [false, false, false] }
    }
}

/// 「Add note」：来源（文件·行号）、文字、可选「作为 # 注释插入代码」、Save note
struct AddNoteSheet: View {
    let project: String
    let file: String?          // nil = 从 Notes 页来的，没有代码来源
    let line: Int
    @Binding var text: String  // 当前文件的文字（插入注释时改它）
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var router: Router
    @State private var note = ""
    @State private var asComment = false
    private var isPy: Bool { file?.hasSuffix(".py") == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Add note").font(.largeTitle.bold()); Spacer()
                AskChatGPTButton { ChatContext.note(source: file, text: note) }
                Button { close() } label: { Image(systemName: "xmark").font(.title3.bold()).foregroundColor(.primary) } }
            if let f = file { Text(tr("%@ · Line %ld", (f as NSString).lastPathComponent, line)).font(.footnote).padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.15))).foregroundColor(.teal) }
            TextEditor(text: $note).frame(height: 110).padding(6)
                .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
            MicButton(text: $note)          // 语音笔记：离线识别，转成文字
            if isPy { Toggle("Insert as # comment", isOn: $asComment).font(.headline).tint(.teal) }
            Button("Save note") { save() }.buttonStyle(TealButtonStyle()).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    private func close() { router.showAddNote = false; dismiss() }

    private func save() {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        NoteStore.add(project, text: n, source: file.map { "\(($0 as NSString).lastPathComponent) · Line \(line)" })
        if asComment && isPy {          // 把笔记作为 # 注释插进代码，放在光标所在行的下面
            var lines = text.components(separatedBy: "\n")
            lines.insert("# " + n.replacingOccurrences(of: "\n", with: " "), at: min(max(line, 0), lines.count))
            text = lines.joined(separator: "\n")
        }
        close()
    }
}
