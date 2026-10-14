import SwiftUI
import AppKit
import LaunchpadCore
import Darwin

enum Scope: Hashable { case all, ungrouped, page(Int64), folder(Int64) }

@MainActor final class Store: ObservableObject {
    @Published var baseline: LaunchpadCore.Layout? { didSet { refreshPresentation() } }
    @Published var draft: LaunchpadCore.Layout? { didSet { refreshPresentation(); persistDraft() } }
    @Published var scope: Scope = .all
    @Published var search = "" { didSet { selected.formIntersection(Set(displayedApps.map(\.id))) } }
    @Published var selected = Set<Int64>()
    @Published var busy = false
    @Published var error: String?
    @Published var status = "正在读取启动台…"
    @Published var undoStack: [LaunchpadCore.Layout] = []
    @Published var redoStack: [LaunchpadCore.Layout] = []
    @Published var backups: [URL] = []
    @Published private(set) var changes: [String] = []
    @Published private(set) var visibleApps: [AppRecord] = []
    @Published private(set) var scopeCounts: [Scope: Int] = [:]
    private var visualOrder: [Int64: Int] = [:]
    private var appPages: [Int64: Int64] = [:]
    private var appFolders: [Int64: Int64] = [:]
    private var selectionAnchor: Int64?
    private var staleDraft = false
    private let draftFileOverride: URL?
    init(draftURL: URL? = nil) { draftFileOverride = draftURL }
    private var draftSaveFailed = false
    var canQuitWithoutLosingDraft: Bool { !draftSaveFailed }
    var draftURL: URL { draftFileOverride ?? backupDirectory.deletingLastPathComponent().appendingPathComponent("PendingDraft.json") }
    @Published var aiConfiguration: AIConfiguration = {
        if let data = UserDefaults.standard.data(forKey: "aiConfiguration"), let saved = try? JSONDecoder().decode(AIConfiguration.self, from: data) { return saved }
        return AIConfiguration()
    }()
    @Published var aiWorking = false
    private var aiTask: Task<Void, Never>?
    var aiConfigured: Bool { UserDefaults.standard.data(forKey: "aiConfiguration") != nil }
    private var databaseURL: URL?
    private var iconCache: [Int64: NSImage] = [:]
    let backupDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LaunchpadTidy/Backups")
    var supported: Bool { [14, 15].contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }
    var hasChanges: Bool { !changes.isEmpty }
    var scopedContainer: Int64? {
        switch scope { case .page(let id), .folder(let id): return id; default: return nil }
    }
    var scopeName: String {
        switch scope {
        case .all: return "全部应用"
        case .ungrouped: return "未归类应用"
        case .page(let id), .folder(let id): return draft?.name(of: id) ?? "应用"
        }
    }
    var displayedApps: [AppRecord] {
        guard draft != nil else { return [] }
        var apps = visibleApps.filter { app in
            let inScope: Bool
            switch scope {
            case .all: inScope = true
            case .ungrouped: inScope = appFolders[app.id] == nil
            case .page(let id): inScope = appPages[app.id] == id
            case .folder(let id): inScope = appFolders[app.id] == id
            }
            return inScope && (search.isEmpty || app.title.localizedCaseInsensitiveContains(search) || app.bundleID.localizedCaseInsensitiveContains(search))
        }
        if scopedContainer != nil {
            apps.sort { (visualOrder[$0.id] ?? 0) < (visualOrder[$1.id] ?? 0) }
        }
        return apps
    }
    func count(_ scope: Scope) -> Int {
        scopeCounts[scope] ?? 0
    }
    private func refreshPresentation() {
        guard let draft else { visibleApps = []; changes = []; scopeCounts = [:]; return }
        visibleApps = draft.visibleApps
        changes = baseline.map { draft.changes(from: $0) } ?? []
        visualOrder = Dictionary(uniqueKeysWithValues: draft.appIDsInLayoutOrder.enumerated().map { ($0.element, $0.offset) })
        appPages = [:]; appFolders = [:]; scopeCounts = [.all: visibleApps.count]
        for app in visibleApps {
            if let page = draft.page(for: app.id) { appPages[app.id] = page; scopeCounts[.page(page), default: 0] += 1 }
            if let folder = draft.folder(for: app.id) { appFolders[app.id] = folder; scopeCounts[.folder(folder), default: 0] += 1 }
            else { scopeCounts[.ungrouped, default: 0] += 1 }
        }
    }
    private func clearSavedDraft() throws {
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
    }
    private func persistDraft() {
        guard let draft, let baseline else { return }
        do {
            if hasChanges {
                if staleDraft, FileManager.default.fileExists(atPath: draftURL.path) {
                    let archived = draftURL.deletingLastPathComponent().appendingPathComponent("StaleDraft-\(UUID().uuidString).json")
                    try FileManager.default.moveItem(at: draftURL, to: archived); staleDraft = false
                }
                try DraftSnapshot(draft: draft, baseline: baseline).save(to: draftURL)
            } else if !staleDraft { try clearSavedDraft() }
            draftSaveFailed = false
        } catch {
            if !draftSaveFailed { self.error = "预览自动保存失败，当前改动仍在内存中：\(error.localizedDescription)" }
            draftSaveFailed = true
        }
    }
    func changeScope(_ value: Scope) { guard !busy else { return }; scope = value; selected.removeAll(); selectionAnchor = nil }
    func load(discardPreview: Bool = false) {
        guard !busy else { return }
        guard supported else {
            status = "此系统暂不支持传统启动台整理"
            error = "当前 macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) 不在已适配范围内。此版支持 macOS 14/15；新版 Spotlight 应用列表尚未适配。"
            return
        }
        busy = true
        Task {
            do {
                let result = try await Task.detached { () -> (URL, LaunchpadCore.Layout) in
                    let url = try LaunchpadDatabase.locate()
                    return (url, try LaunchpadDatabase.load(url))
                }.value
                var restored = result.1
                var recovered = false
                if discardPreview { try clearSavedDraft(); staleDraft = false }
                else {
                    staleDraft = false
                    do {
                        if let saved = try DraftSnapshot.load(from: draftURL) { restored = try saved.restore(on: result.1); recovered = true }
                    } catch { staleDraft = true; self.error = error.localizedDescription }
                }
                databaseURL = result.0; baseline = result.1; draft = restored
                selected.removeAll(); undoStack.removeAll(); redoStack.removeAll(); iconCache.removeAll()
                if recovered { undoStack.append(result.1) }
                scope = .all; status = recovered ? "已恢复上次未应用的预览 · 可继续编辑或撤销" : "已读取 \(result.1.visibleApps.count) 个应用 · 编辑后预览，再应用"
                refreshBackups()
            } catch { self.error = error.localizedDescription; status = "读取失败，可以重试" }
            busy = false
        }
    }
    @discardableResult func edit(_ action: (inout LaunchpadCore.Layout) throws -> Void) -> Bool {
        guard !busy, var layout = draft, let baseline else { return false }
        do {
            try action(&layout)
            try layout.validate(against: baseline)
            guard layout != draft else { return true }
            if let draft { undoStack.append(draft); if undoStack.count > 50 { undoStack.removeFirst() } }
            redoStack.removeAll(); draft = layout
            status = "预览已更新 · \(changes.count) 项待应用变更"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func undo() {
        guard !busy, let last = undoStack.popLast(), let draft else { return }
        redoStack.append(draft); self.draft = last; selected.removeAll(); repairScope()
        status = "已撤销 · \(changes.count) 项待应用变更"
    }
    func redo() {
        guard !busy, let next = redoStack.popLast(), let draft else { return }
        undoStack.append(draft); self.draft = next; selected.removeAll(); repairScope()
        status = "已重做 · \(changes.count) 项待应用变更"
    }
    func discard() { guard !busy else { return }; draft = baseline; undoStack.removeAll(); redoStack.removeAll(); selected.removeAll(); repairScope(); status = "已撤销全部预览改动" }
    func repairScope() { if let id = scopedContainer, draft?.items[id] == nil { scope = .all } }
    func select(_ id: Int64) {
        guard !busy else { return }
        let order = displayedApps.map(\.id)
        if NSEvent.modifierFlags.contains(.shift), let anchor = selectionAnchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            selected.formUnion(order[min(from, to)...max(from, to)])
        } else { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }; selectionAnchor = id }
    }
    func moveSelected(to id: Int64) { let ids = selected; if edit({ try $0.move(ids, to: id) }) { selected.removeAll() } }
    func suggestCategories() {
        let ids = selected.isEmpty ? Set(displayedApps.map(\.id)) : selected
        let succeeded = edit { layout in
            let candidates = layout.visibleApps.filter { ids.contains($0.id) && layout.folder(for: $0.id) == nil }
            let groups = Dictionary(grouping: candidates.compactMap { app -> (AppRecord, String)? in
                Categorizer.suggestion(for: app).map { (app, $0) }
            }, by: { $0.1 })
            for name in groups.keys.sorted() {
                let target: Int64
                if let existing = layout.folders.first(where: { layout.name(of: $0.id) == name }) { target = existing.id }
                else {
                    let capacity = layout.pageCapacity
                    let page = layout.pages.first(where: { layout.children(of: $0.id).count < capacity })?.id ?? layout.addPage()
                    target = try layout.addFolder(title: name, on: page)
                }
                try layout.move(Set(groups[name]!.map { $0.0.id }), to: target)
            }
        }
        if succeeded { selected.removeAll(); status = "已生成本地分类预览 · 仅整理未归类应用" }
    }
    func organizeWithAI() {
        guard !busy, let original = draft else { return }
        let configuration = aiConfiguration
        let candidates = Set(configuration.candidates(in: original).map(\.id))
        guard !candidates.isEmpty else { error = "没有需要 AI 整理的应用。"; return }
        let key: String
        do { _ = try configuration.endpoint(); key = try AICredentials.load(configuration); try configuration.validateCredential(key) }
        catch { self.error = error.localizedDescription; return }
        busy = true; aiWorking = true; status = "AI 正在整理 \(candidates.count) 个应用…"
        aiTask = Task {
            defer { busy = false; aiWorking = false; aiTask = nil }
            do {
                let plan = try await AIClient().organize(layout: original, configuration: configuration, apiKey: key)
                try Task.checkCancellation()
                let preview = try plan.preview(on: original, candidates: candidates)
                if let baseline { try preview.validate(against: baseline) }
                try Task.checkCancellation()
                guard self.draft == original else { throw TidyError.message("预览已发生变化，请重新进行 AI 整理。") }
                if preview != original {
                    undoStack.append(original); if undoStack.count > 50 { undoStack.removeFirst() }
                    redoStack.removeAll(); draft = preview; selected.removeAll(); repairScope()
                    status = "AI 已生成 \(plan.groups.count) 类预览 · \(plan.unassigned.count) 个应用保留原位 · 可撤销后重新整理"
                } else { status = "AI 整理完成，当前布局无需调整" }
            } catch is CancellationError { status = "已取消 AI 整理，预览未改变" }
            catch { self.error = error.localizedDescription; status = "AI 整理未完成，预览未改变" }
        }
    }
    func cancelAI() { aiTask?.cancel() }
    func icon(for app: AppRecord) -> NSImage {
        if let icon = iconCache[app.id] { return icon }
        let icon: NSImage
        if let url = applicationURL(app) { icon = NSWorkspace.shared.icon(forFile: url.path) }
        else { icon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: app.title)! }
        iconCache[app.id] = icon
        return icon
    }
    func applicationURL(_ app: AppRecord) -> URL? {
        if let bookmark = app.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
    }
    func reveal(_ app: AppRecord) { if let url = applicationURL(app) { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { error = "找不到该应用的文件位置。" } }
    func launch(_ app: AppRecord) { if let url = applicationURL(app) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) } else { error = "应用文件已不存在，请重新读取启动台。" } }
    func refreshBackups() {
        backups = ((try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    func apply() {
        guard let draft, let baseline, let url = databaseURL, !busy, supported else { return }
        do { try draft.validate(against: baseline) } catch { self.error = error.localizedDescription; return }
        busy = true; status = "正在备份并应用布局…"
        let directory = backupDirectory
        Task {
            do {
                let dock = try DockPause()
                let deadline = Date().addingTimeInterval(12)
                let backup: URL
                do {
                    backup = try await Task.detached { try LaunchpadDatabase.apply(draft, baseline: baseline, to: url, backupDirectory: directory, deadline: deadline) }.value
                } catch { dock.resume(); throw error }
                let restarted = dock.restart()
                // Commit has succeeded. A refresh failure must not be reported as a failed write.
                self.baseline = nil; self.draft = nil
                undoStack.removeAll(); redoStack.removeAll(); selected.removeAll(); repairScope(); refreshBackups()
                staleDraft = false
                do { try clearSavedDraft() } catch { self.error = "布局已写入，但旧预览缓存清理失败。" }
                do {
                    let updated = try await Task.detached { try LaunchpadDatabase.load(url) }.value
                    self.baseline = updated; self.draft = updated
                    status = restarted ? "已应用 · 自动备份：\(backup.lastPathComponent)" : "布局已写入并备份，但 Dock 刷新失败，请重新打开启动台"
                } catch {
                    self.error = "布局已成功写入并备份，但重新读取失败。请点击重新读取；不要重复应用。\n\(error.localizedDescription)"
                    status = "布局已写入 · 等待重新读取"
                }
            } catch { self.error = error.localizedDescription; status = "应用未完成，请查看提示" }
            busy = false
        }
    }
    func previewRestore(_ url: URL) {
        guard let baseline, !busy else { return }
        busy = true; status = "正在校验并载入备份…"
        Task {
            defer { busy = false }
            do {
                let layout = try await Task.detached { try LaunchpadDatabase.restoration(from: url, current: baseline) }.value
                if let draft { undoStack.append(draft); if undoStack.count > 50 { undoStack.removeFirst() } }
                draft = layout; redoStack.removeAll(); selected.removeAll(); repairScope()
                status = "备份已载入预览 · 可撤销；应用前仍会备份当前布局"
            } catch { self.error = error.localizedDescription; status = "备份载入失败，预览未改变" }
        }
    }
}

/// Pause Dock briefly so its in-memory layout cannot race the SQLite transaction.
/// A separate watchdog resumes it if this app exits unexpectedly.
@MainActor final class DockPause {
    private let pid: pid_t
    private let watchdog: Process
    private var finished = false
    init() throws {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { throw TidyError.message("Dock 未运行，请稍后再试。") }
        pid = dock.processIdentifier
        guard kill(pid, SIGSTOP) == 0 else { throw TidyError.message("无法暂停当前用户的 Dock，未修改启动台。") }
        watchdog = Process(); watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", "sleep 20; kill -CONT \"$1\"", "launchpad-tidy-watchdog", String(pid)]
        watchdog.standardOutput = FileHandle.nullDevice; watchdog.standardError = FileHandle.nullDevice
        do { try watchdog.run() } catch { kill(pid, SIGCONT); throw error }
    }
    func resume() { guard !finished else { return }; kill(pid, SIGCONT); finish() }
    func restart() -> Bool { guard !finished else { return false }; let succeeded = kill(pid, SIGKILL) == 0; if !succeeded { kill(pid, SIGCONT) }; finish(); return succeeded }
    private func finish() { finished = true; if watchdog.isRunning { watchdog.terminate() } }
    deinit { if !finished { kill(pid, SIGCONT); if watchdog.isRunning { watchdog.terminate() } } }
}
