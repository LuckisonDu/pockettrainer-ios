// FilesView.swift —— 「Project files」：搜索 + 文件树 + 每行的「…」菜单（都是沙盒里的真实文件操作）
import SwiftUI

struct FileItem: Identifiable, Hashable {
    let url: URL, isDir: Bool, depth: Int
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct FilesView: View {
    let project: String
    @EnvironmentObject var router: Router
    @State private var expanded: Set<URL> = []
    @State private var query = ""
    @State private var items: [FileItem] = []
    // 菜单动作需要的状态
    private enum Action { case newFile, newFolder, rename, delete }
    @State private var target: FileItem?          // 菜单作用的那一行（nil = 项目根目录）
    @State private var action: Action?
    @State private var text = ""
    @State private var moving: FileItem?

    private var root: URL { ProjectStore.dir(project) }

    var body: some View {
        VStack(spacing: 8) {
            HStack { Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search files", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled() }
                .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackground))
            List {
                row(FileItem(url: root, isDir: true, depth: 0), isRoot: true)
                ForEach(visible) { row($0) }
            }.listStyle(.plain)
        }
        .padding(.horizontal, 12)
        .background(Color.pageBackground)
        .navigationTitle("Project files").navigationBarTitleDisplayMode(.inline)
        .toolbar { AskChatGPTButton { ChatContext.files(project) } }
        .onAppear { reload() }
        .alert(alertTitle, isPresented: Binding(get: { action == .newFile || action == .newFolder || action == .rename }, set: { if !$0 { action = nil } })) {
            TextField("Name", text: $text)
            Button("OK") { perform() }; Button("Cancel", role: .cancel) {}
        }
        .alert(tr("Delete %@?", target?.name ?? ""), isPresented: Binding(get: { action == .delete }, set: { if !$0 { action = nil } })) {
            Button("Delete", role: .destructive) { perform() }; Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
        .sheet(item: $moving) { item in MoveSheet(item: item, root: root) { reload() } }
    }

    private var alertTitle: String { action == .newFile ? tr("New file") : action == .newFolder ? tr("New folder") : tr("Rename") }

    // MARK: 文件树

    /// 按展开状态（或搜索词）算出要显示的行
    private var visible: [FileItem] {
        if !query.isEmpty { return items.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        return items.filter { it in
            var p = it.url.deletingLastPathComponent()
            while p != root { if !expanded.contains(p) { return false }; p = p.deletingLastPathComponent() }
            return true
        }
    }

    private func reload() {
        func walk(_ dir: URL, _ depth: Int) -> [FileItem] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            return names.flatMap { n -> [FileItem] in
                let u = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false; FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                let it = FileItem(url: u, isDir: isDir.boolValue, depth: depth)
                return [it] + (isDir.boolValue ? walk(u, depth + 1) : [])
            }
        }
        items = walk(root, 0)
    }

    private func row(_ it: FileItem, isRoot: Bool = false) -> some View {
        HStack(spacing: 8) {
            if it.isDir {
                Image(systemName: expanded.contains(it.url) || isRoot ? "chevron.down" : "chevron.right").font(.caption).frame(width: 14)
                Image(systemName: "folder.fill").foregroundColor(.teal)
            } else { Spacer().frame(width: 14); Image(systemName: it.name.hasSuffix(".md") ? "doc.text" : "doc").foregroundColor(.secondary) }
            Text(isRoot ? project : it.name).font(isRoot ? .headline : .body).lineLimit(1)
            Spacer()
            Menu {
                Button { target = it; text = ""; action = .newFile } label: { Label("New file", systemImage: "doc.badge.plus") }
                Button { target = it; text = ""; action = .newFolder } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Divider()
                if !it.isDir { Button { open(it) } label: { Label("Open", systemImage: "arrow.up.right.square") } }
                if !isRoot {
                    Button { target = it; text = it.name; action = .rename } label: { Label("Rename", systemImage: "pencil") }
                    Button { duplicate(it) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { moving = it } label: { Label("Move", systemImage: "folder") }
                    if !it.isDir { ShareLink(item: it.url) { Label("Share", systemImage: "square.and.arrow.up") } }
                    Button(role: .destructive) { target = it; action = .delete } label: { Label("Delete", systemImage: "trash") }
                }
            } label: { Image(systemName: "ellipsis").foregroundColor(.secondary).frame(width: 30, height: 30) }
        }
        .padding(.leading, CGFloat(it.depth) * 18)
        .contentShape(Rectangle())
        .onTapGesture {
            if it.isDir { if expanded.contains(it.url) { expanded.remove(it.url) } else { expanded.insert(it.url) } }
            else { open(it) }
        }
    }

    // MARK: 文件操作

    private func open(_ it: FileItem) {
        router.openFile = String(it.url.path.dropFirst(root.path.count + 1))
        router.path = [.editor(project)]
    }

    /// 新建时放在哪个文件夹：选中的是文件夹就放里面，是文件就放它旁边
    private func parentDir() -> URL { target.map { $0.isDir ? $0.url : $0.url.deletingLastPathComponent() } ?? root }

    private func perform() {
        let fm = FileManager.default
        let name = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        switch action {
        case .newFile where !name.isEmpty: fm.createFile(atPath: parentDir().appendingPathComponent(name).path, contents: Data())
        case .newFolder where !name.isEmpty: try? fm.createDirectory(at: parentDir().appendingPathComponent(name), withIntermediateDirectories: true)
        case .rename where !name.isEmpty: if let t = target { try? fm.moveItem(at: t.url, to: t.url.deletingLastPathComponent().appendingPathComponent(name)) }
        case .delete: if let t = target { try? fm.removeItem(at: t.url) }
        default: break
        }
        action = nil; reload()
    }

    private func duplicate(_ it: FileItem) {
        let ext = it.url.pathExtension, base = it.url.deletingPathExtension().lastPathComponent
        let copy = it.url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)")
        try? FileManager.default.copyItem(at: it.url, to: copy); reload()
    }
}

/// 「Move」：选一个目标文件夹
struct MoveSheet: View {
    let item: FileItem, root: URL
    var done: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            let folders = ([root] + ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL]) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }).filter { !$0.path.hasPrefix(item.url.path) }
            List(folders, id: \.self) { f in
                Button(f == root ? tr("Project root") : String(f.path.dropFirst(root.path.count + 1))) {
                    try? FileManager.default.moveItem(at: item.url, to: f.appendingPathComponent(item.name)); done(); dismiss()
                }
            }
            .navigationTitle(tr("Move %@ to…", item.name)).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }.presentationDetents([.medium])
    }
}
