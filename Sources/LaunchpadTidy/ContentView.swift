import SwiftUI
import LaunchpadCore
import AppKit

private let mint = Color(red: 0.18, green: 0.48, blue: 0.37)
private let canvas = Color(nsColor: .windowBackgroundColor)

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var folderSheet = false
    @State private var renameID: Int64?
    @State private var folderName = ""
    @State private var folderPage: Int64 = 0
    @State private var moveIntoFolder = true
    @State private var previewSheet = false
    @State private var pagesExpanded = false
    @State private var foldersExpanded = true
    @State private var confirmReload = false
    @State private var dissolveID: Int64?
    @State private var aiSettings = false
    @State private var aiStartAfterSave = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 800
            HStack(spacing: 0) {
                if !compact {
                    sidebar.frame(width: 164)
                    Divider()
                }
                VStack(spacing: 0) {
                    header(compact: compact)
                    Divider()
                    mainContent
                    Divider()
                    bottomBar
                }
            }
        }
        .background(canvas)
        .tint(mint)
        .onReceive(NotificationCenter.default.publisher(for: .tidyFocusSearch)) { _ in searchFocused = true }
        .sheet(isPresented: $folderSheet) { folderEditor }
        .sheet(isPresented: $previewSheet) { previewDetails }
        .sheet(isPresented: $aiSettings) { AISettingsView(configuration: store.aiConfiguration, startAfterSave: aiStartAfterSave).environmentObject(store) }
        .alert("操作提示", isPresented: Binding(get: { store.error != nil && !folderSheet && !aiSettings }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("重新读取会放弃当前预览改动。", isPresented: $confirmReload) {
            Button("放弃预览并重新读取", role: .destructive) { store.load(discardPreview: true) }
        }
        .confirmationDialog("解散文件夹后，应用会回到所在页面。", isPresented: Binding(get: { dissolveID != nil }, set: { if !$0 { dissolveID = nil } })) {
            Button("解散文件夹", role: .destructive) {
                if let id = dissolveID { store.edit { try $0.dissolveFolder(id) }; store.repairScope() }; dissolveID = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("启动台整理").font(.headline)
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("应用")
                    scopeRow("全部应用", symbol: "square.grid.2x2", scope: .all)
                    scopeRow("未归类", symbol: "tray", scope: .ungrouped)
                    DisclosureGroup("页面", isExpanded: $pagesExpanded) {
                        ForEach(store.draft?.pages ?? []) { page in
                            scopeRow(store.draft!.name(of: page.id), symbol: "rectangle.on.rectangle", scope: .page(page.id))
                        }
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 20)
                    DisclosureGroup("文件夹", isExpanded: $foldersExpanded) {
                        ForEach(store.draft?.folders ?? []) { folder in
                            scopeRow(store.draft!.name(of: folder.id), symbol: "folder", scope: .folder(folder.id))
                                .contextMenu {
                                    Button("重命名") { openFolderEditor(folder.id) }
                                    Button("按名称排序") { store.edit { $0.sort(container: folder.id) } }
                                    Button("解散文件夹", role: .destructive) { dissolveID = folder.id }
                                }
                        }
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 20)
                }.padding(.horizontal, 10).padding(.bottom, 20)
            }
            Spacer(minLength: 0)
            Text("预览自动保存").font(.caption2).foregroundStyle(.tertiary).padding(20)
        }
        .background(mint.opacity(0.035))
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.bottom, 8)
    }
    private func scopeRow(_ title: String, symbol: String, scope: Scope) -> some View {
        Button { store.changeScope(scope) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: store.scope == scope ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(store.count(scope))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .foregroundStyle(store.scope == scope ? mint : Color.primary.opacity(0.8))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(store.scope == scope ? mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.busy)
        .dropDestination(for: String.self) { values, _ in
            guard case .page(let id) = scope else {
                if case .folder(let id) = scope { return drop(values, into: id) }; return false
            }
            return drop(values, into: id)
        }
    }
    private func drop(_ values: [String], into container: Int64) -> Bool {
        guard !store.busy else { return false }
        let ids = Set(values.compactMap(Int64.init))
        guard !ids.isEmpty else { return false }
        let moving = ids.isSubset(of: store.selected) ? store.selected : ids
        let succeeded = store.edit { try $0.move(moving, to: container) }
        if succeeded { store.selected.removeAll() }
        return succeeded
    }

    private func header(compact: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if compact {
                    Menu { scopeActions } label: {
                        Text(store.scopeName).font(.headline).lineLimit(1)
                    }.menuStyle(.borderlessButton).frame(maxWidth: .infinity, alignment: .leading).help("切换应用范围")
                } else {
                    Text(store.scopeName).font(.headline).lineLimit(1)
                }
                Text("\(store.displayedApps.count)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu { moreActions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24).help("更多操作").disabled(store.busy)
                if store.hasChanges { aiAction.buttonStyle(.bordered) }
                else { aiAction.buttonStyle(.borderedProminent) }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用", text: $store.search).textFieldStyle(.plain).focused($searchFocused)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }.padding(7).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }.padding(14)
    }
    @ViewBuilder private var scopeActions: some View {
        scopeOption("全部应用", scope: .all)
        scopeOption("未归类", scope: .ungrouped)
        Divider()
        ForEach(store.draft?.pages ?? []) { page in
            scopeOption(store.draft!.name(of: page.id), scope: .page(page.id))
        }
        Divider()
        ForEach(store.draft?.folders ?? []) { folder in
            scopeOption(folderLabel(folder), scope: .folder(folder.id))
        }
    }
    private func scopeOption(_ title: String, scope: Scope) -> some View {
        Button { store.changeScope(scope) } label: {
            if store.scope == scope { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }.disabled(store.busy)
    }
    private var aiAction: some View {
        Button {
            if store.aiConfigured { store.organizeWithAI() }
            else { aiStartAfterSave = true; aiSettings = true }
        } label: { Label("AI 整理", systemImage: "sparkles") }
            .controlSize(.regular).disabled(store.draft == nil || store.busy)
            .help(store.aiConfiguration.onlyUngrouped ? "整理全部未归类应用，生成预览" : "整理全部应用，生成预览")
    }
    @ViewBuilder private var moreActions: some View {
        Button("AI 设置…") { aiStartAfterSave = false; aiSettings = true }
        if case .folder(let id) = store.scope {
            Button("重命名文件夹…") { openFolderEditor(id) }
            Button("解散文件夹", role: .destructive) { dissolveID = id }
        }
        Divider()
        Button("本地分类") { store.suggestCategories() }.disabled(store.draft == nil)
        Button("按名称排序") { store.edit { $0.sort(container: store.scopedContainer) } }.disabled(store.draft == nil || !store.search.isEmpty)
        Button("新建文件夹…") { openFolderEditor() }.disabled(store.draft == nil)
        Button("添加页面") { store.edit { _ = $0.addPage() }; pagesExpanded = true }.disabled(store.draft == nil)
        Button("清理空页") { if store.edit({ $0.removeEmptyPages() }) { store.repairScope() } }.disabled((store.draft?.pages.count ?? 0) < 2)
        Divider()
        Button("撤销") { store.undo() }.disabled(store.undoStack.isEmpty)
        Button("重做") { store.redo() }.disabled(store.redoStack.isEmpty)
        Button("放弃全部改动") { store.discard() }.disabled(!store.hasChanges)
        Menu("备份与恢复") {
            Button("打开备份目录") {
                do {
                    try FileManager.default.createDirectory(at: store.backupDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.backupDirectory)
                } catch { store.error = error.localizedDescription }
            }
            Divider()
            if store.backups.isEmpty { Text("应用时自动备份") }
            ForEach(Array(store.backups.prefix(30)), id: \.self) { url in
                Button(backupLabel(url)) { store.previewRestore(url) }
            }
        }
        Button("重新读取") { if store.hasChanges { confirmReload = true } else { store.load() } }
    }
    private var mainContent: some View {
        VStack(spacing: 0) {
            if store.busy && store.draft == nil {
                Spacer(); ProgressView("读取启动台…"); Spacer()
            } else if store.draft == nil {
                ContentUnavailableView("无法读取启动台", systemImage: "square.grid.2x2", description: Text(store.status))
                Button("重新读取") { store.load() }.padding(.bottom, 24).disabled(store.busy)
            } else if store.displayedApps.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? "暂无应用" : "未找到应用", systemImage: store.search.isEmpty ? "tray" : "magnifyingglass")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 116), spacing: 10)], spacing: 10) {
                        ForEach(store.displayedApps) { app in appTile(app) }
                    }.padding(14)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(store.busy)
    }
    private func appTile(_ app: AppRecord) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: store.icon(for: app)).resizable().scaledToFit().frame(width: 44, height: 44)
            Text(app.title).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).frame(height: 30)
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(store.selected.contains(app.id) ? mint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(store.selected.contains(app.id) ? mint.opacity(0.65) : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if store.selected.contains(app.id) { selectionIndicator(app.id).padding(5) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.launch(app) }
        .onTapGesture { store.select(app.id) }
        .draggable(String(app.id))
        .dropDestination(for: String.self) { values, _ in
            guard let id = values.first.flatMap(Int64.init), values.count == 1, !store.busy else { return false }
            return store.edit { try $0.reorder(id, before: app.id) }
        }
        .contextMenu { appMenu(app) }
        .help("\(app.title)\n\(store.draft?.location(of: app.id) ?? "")\n单击选择，双击打开；拖到侧栏可移动，拖到其他应用前可排序。")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.title)，\(store.draft?.location(of: app.id) ?? "")")
        .accessibilityAddTraits(store.selected.contains(app.id) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.select(app.id) }
    }
    private func selectionIndicator(_ id: Int64) -> some View {
        Image(systemName: store.selected.contains(id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13)).foregroundStyle(store.selected.contains(id) ? mint : Color.primary.opacity(0.12))
    }
    @ViewBuilder private func appMenu(_ app: AppRecord) -> some View {
        Button("打开应用") { store.launch(app) }
        Button("在 Finder 中显示") { store.reveal(app) }
        Menu("移动到") {
            ForEach(store.draft?.pages ?? []) { page in
                Button(store.draft!.name(of: page.id)) { store.edit { try $0.move([app.id], to: page.id) } }
            }
            Divider()
            ForEach(store.draft?.folders ?? []) { folder in
                Button(folderLabel(folder)) { store.edit { try $0.move([app.id], to: folder.id) } }
            }
        }
    }
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !store.selected.isEmpty && !store.busy {
                HStack(spacing: 12) {
                    Text("已选 \(store.selected.count) 个").font(.caption)
                    Menu("移动到") {
                        ForEach(store.draft?.pages ?? []) { page in Button(store.draft!.name(of: page.id)) { store.moveSelected(to: page.id) } }
                        Divider()
                        ForEach(store.draft?.folders ?? []) { folder in Button(folderLabel(folder)) { store.moveSelected(to: folder.id) } }
                    }
                    Button("建文件夹") { openFolderEditor() }
                    Button { store.selected.removeAll() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("取消选择")
                    Spacer()
                }
            }
            HStack(spacing: 12) {
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.hasChanges && !store.busy ? "预览 · 应用时自动备份" : store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(store.status)
                Spacer(minLength: 8)
                if store.aiWorking { Button("取消") { store.cancelAI() } }
                if store.hasChanges {
                    Button("\(store.changes.count) 项改动") { previewSheet = true }.buttonStyle(.borderless).disabled(store.busy)
                    Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("撤销 · ⌘Z").disabled(store.undoStack.isEmpty || store.busy)
                    Button("应用") { store.apply() }.buttonStyle(.borderedProminent).controlSize(.regular)
                        .disabled(store.busy).help("自动备份并应用，Dock 会短暂刷新")
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func openFolderEditor(_ id: Int64? = nil) {
        store.error = nil
        renameID = id; folderName = id.map { store.draft?.name(of: $0) ?? "" } ?? ""
        folderPage = id.flatMap { store.draft?.items[$0]?.parent } ?? { if case .page(let page) = store.scope { return page }; return store.draft?.pages.first?.id ?? 0 }()
        moveIntoFolder = !store.selected.isEmpty; folderSheet = true
    }
    private var folderEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(renameID == nil ? "新建文件夹" : "重命名文件夹").font(.title2.bold())
            TextField("文件夹名称", text: $folderName).textFieldStyle(.roundedBorder)
            if renameID == nil {
                Picker("所在页面", selection: $folderPage) { ForEach(store.draft?.pages ?? []) { page in Text(store.draft!.name(of: page.id)).tag(page.id) } }
                if !store.selected.isEmpty { Toggle("将已选的 \(store.selected.count) 个应用移入", isOn: $moveIntoFolder) }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer(); Button("取消") { store.error = nil; folderSheet = false }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let name = folderName, page = folderPage, ids = store.selected, moving = moveIntoFolder
                    let succeeded = store.edit { layout in
                        if let id = renameID { try layout.renameFolder(id, to: name) }
                        else { let id = try layout.addFolder(title: name, on: page); if moving { try layout.move(ids, to: id) } }
                    }
                    if succeeded { store.selected.removeAll(); folderSheet = false }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 380)
    }
    private var previewDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(store.changes.count) 项改动").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(store.changes.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: 220)
            Text("应用时自动备份，Dock 会短暂刷新。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("放弃改动") { store.discard(); previewSheet = false }.disabled(store.busy)
                Spacer()
                Button("关闭") { previewSheet = false }.keyboardShortcut(.cancelAction)
                Button("应用到启动台") { previewSheet = false; store.apply() }.buttonStyle(.borderedProminent).disabled(!store.hasChanges || store.busy)
            }
        }.padding(22).frame(width: 440)
    }
    private func folderLabel(_ folder: Item) -> String { "\(store.draft!.name(of: folder.id)) · \(store.draft!.name(of: folder.parent))" }
    private func backupLabel(_ url: URL) -> String {
        let stamp = url.deletingPathExtension().lastPathComponent.split(separator: "-").dropFirst().first.flatMap { TimeInterval($0) }
        let suffix = url.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init) ?? ""
        return stamp.map { Date(timeIntervalSince1970: $0).formatted(date: .numeric, time: .standard) + " · " + suffix } ?? url.lastPathComponent
    }
}
