import Foundation

public struct Item: Codable, Equatable, Identifiable {
    public var id: Int64
    public var uuid: String
    public var flags: Int64?
    public var type: Int64
    public var parent: Int64
    public var order: Int64
    public init(id: Int64, uuid: String, flags: Int64? = 0, type: Int64, parent: Int64, order: Int64) {
        self.id = id; self.uuid = uuid; self.flags = flags; self.type = type; self.parent = parent; self.order = order
    }
}

public struct AppRecord: Codable, Equatable, Identifiable {
    public var id: Int64
    public var title: String
    public var bundleID: String
    public var bookmark: Data?
    public init(id: Int64, title: String, bundleID: String, bookmark: Data? = nil) {
        self.id = id; self.title = title; self.bundleID = bundleID; self.bookmark = bookmark
    }
}

public struct Layout: Equatable {
    public var items: [Int64: Item]
    public var titles: [Int64: String]
    public var apps: [Int64: AppRecord]
    public var root: Int64
    public var fingerprint: String
    public var inventory: String
    public init(items: [Int64: Item], titles: [Int64: String], apps: [Int64: AppRecord], root: Int64, fingerprint: String = "", inventory: String = "") {
        self.items = items; self.titles = titles; self.apps = apps; self.root = root
        self.fingerprint = fingerprint; self.inventory = inventory
    }
    public func children(of id: Int64) -> [Item] {
        items.values.filter { $0.parent == id }.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }
    public var pages: [Item] {
        children(of: root).filter { $0.type == 3 && !$0.uuid.hasPrefix("HOLDINGPAGE") }
    }
    public var folders: [Item] {
        pages.flatMap { children(of: $0.id).filter { $0.type == 2 } }
    }
    public var visibleApps: [AppRecord] {
        apps.values.filter { isVisible($0.id) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    /// Follow the actual hierarchy rather than comparing unrelated folder-page orders.
    public var appIDsInLayoutOrder: [Int64] {
        func walk(_ container: Int64) -> [Int64] {
            children(of: container).flatMap { item -> [Int64] in
                if item.type == 4 { return apps[item.id] == nil ? [] : [item.id] }
                if item.type == 2 || item.type == 3 { return walk(item.id) }
                return []
            }
        }
        return pages.flatMap { walk($0.id) }
    }
    public var pageCapacity: Int { max(35, pages.map { children(of: $0.id).count }.max() ?? 35) }
    public mutating func removeEmptyPages() {
        let originalPages = pages
        var remaining = originalPages.count
        for page in originalPages.reversed() where remaining > 1 && children(of: page.id).isEmpty {
            items.removeValue(forKey: page.id); titles.removeValue(forKey: page.id); remaining -= 1
        }
        normalize(root)
    }
    public func isVisible(_ id: Int64) -> Bool {
        var current = id
        var visited = Set<Int64>()
        while let item = items[current], visited.insert(current).inserted {
            if item.uuid.hasPrefix("HOLDINGPAGE") { return false }
            if current == root { return true }
            current = item.parent
        }
        return false
    }
    public func folder(for appID: Int64) -> Int64? {
        guard let parent = items[appID]?.parent, let page = items[parent], let folder = items[page.parent], folder.type == 2 else { return nil }
        return folder.id
    }
    public func page(for appID: Int64) -> Int64? {
        var current = appID
        var visited = Set<Int64>()
        while let item = items[current], visited.insert(current).inserted {
            if pages.contains(where: { $0.id == item.id }) { return item.id }
            current = item.parent
        }
        return nil
    }
    public func name(of id: Int64) -> String {
        if let app = apps[id] { return app.title }
        if let title = titles[id], !title.isEmpty { return title }
        if let index = pages.firstIndex(where: { $0.id == id }) { return "第 \(index + 1) 页" }
        return "未命名文件夹"
    }
    public func location(of appID: Int64) -> String {
        [page(for: appID).map { name(of: $0) }, folder(for: appID).map { name(of: $0) }].compactMap { $0 }.joined(separator: " / ")
    }
    private var nextID: Int64 { min(items.keys.min() ?? 0, 0) - 1 }
    @discardableResult public mutating func addPage() -> Int64 {
        let id = nextID
        items[id] = Item(id: id, uuid: UUID().uuidString, type: 3, parent: root, order: Int64(pages.count))
        normalize(root)
        return id
    }
    @discardableResult public mutating func addFolder(title: String, on page: Int64) throws -> Int64 {
        guard pages.contains(where: { $0.id == page }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TidyError.message("请选择页面，并填写文件夹名称。") }
        let id = nextID
        items[id] = Item(id: id, uuid: UUID().uuidString, type: 2, parent: page, order: Int64(children(of: page).count))
        titles[id] = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let child = nextID
        items[child] = Item(id: child, uuid: UUID().uuidString, type: 3, parent: id, order: 0)
        return id
    }
    public mutating func renameFolder(_ id: Int64, to title: String) throws {
        guard folders.contains(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TidyError.message("文件夹名称不能为空。") }
        titles[id] = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public mutating func move(_ appIDs: Set<Int64>, to container: Int64) throws {
        guard let target = items[container], (pages.contains { $0.id == container } || folders.contains { $0.id == container }) else { throw TidyError.message("目标页面或文件夹不存在。") }
        guard appIDs.allSatisfy({ apps[$0] != nil && isVisible($0) }) else { throw TidyError.message("只能移动可见的启动台应用。") }
        var destination = container
        if target.type == 2 {
            guard let first = children(of: container).first(where: { $0.type == 3 }) else { throw TidyError.message("文件夹结构不受支持。") }
            destination = first.id
        }
        var sourceParents = Set<Int64>()
        for id in appIDs.sorted() {
            guard var item = items[id] else { continue }
            if target.type == 2 {
                if children(of: container).contains(where: { $0.id == item.parent }) { continue }
                if let available = children(of: container).first(where: { children(of: $0.id).count < 16 }) {
                    destination = available.id
                } else {
                    destination = nextID
                    items[destination] = Item(id: destination, uuid: UUID().uuidString, type: 3, parent: container, order: Int64(children(of: container).count))
                }
            }
            guard item.parent != destination else { continue }
            sourceParents.insert(item.parent)
            item.parent = destination; item.order = Int64(children(of: destination).count)
            items[id] = item
        }
        for parent in sourceParents.union([destination]) { normalize(parent) }
    }
    public mutating func dissolveFolder(_ id: Int64) throws {
        guard let folder = items[id], folders.contains(where: { $0.id == id }) else { throw TidyError.message("文件夹不存在。") }
        let capacity = pageCapacity
        let ids = appIDsInLayoutOrder.filter { self.folder(for: $0) == id }
        for appID in ids {
            let preferredCount = children(of: folder.parent).filter { $0.id != id }.count
            let destination = preferredCount < capacity ? folder.parent : pages.first(where: { children(of: $0.id).count < capacity })?.id ?? addPage()
            let order = Int64(children(of: destination).count)
            items[appID]?.parent = destination; items[appID]?.order = order
        }
        for child in children(of: id) {
            guard children(of: child.id).isEmpty else { throw TidyError.message("文件夹含有不支持的项目，无法解散。") }
            items.removeValue(forKey: child.id); titles.removeValue(forKey: child.id)
        }
        items.removeValue(forKey: id); titles.removeValue(forKey: id); normalize(folder.parent)
        for page in pages { normalize(page.id) }
    }
    public mutating func normalize(_ parent: Int64) {
        // Holding pages are internal system storage, not normal pages.
        for (index, item) in children(of: parent).filter({ !$0.uuid.hasPrefix("HOLDINGPAGE") }).enumerated() {
            items[item.id]?.order = Int64(index)
        }
    }
    public mutating func sort(container: Int64?) {
        let folderIDs = container.map { items[$0]?.type == 2 ? [$0] : [] } ?? folders.map(\.id)
        for id in folderIDs {
            let ids = children(of: id).flatMap { children(of: $0.id) }.sorted { name(of: $0.id).localizedStandardCompare(name(of: $1.id)) == .orderedAscending }.map(\.id)
            repackFolder(id, orderedIDs: ids)
        }
        let parents = container.map { items[$0]?.type == 2 ? [] : [$0] } ?? pages.map(\.id)
        for parent in parents {
            let sorted = children(of: parent).sorted { name(of: $0.id).localizedStandardCompare(name(of: $1.id)) == .orderedAscending }
            for (index, item) in sorted.enumerated() { items[item.id]?.order = Int64(index) }
        }
    }
    private mutating func repackFolder(_ id: Int64, orderedIDs: [Int64]) {
        var folderPages = children(of: id)
        while folderPages.count < max(1, (orderedIDs.count + 15) / 16) {
            let newID = nextID
            items[newID] = Item(id: newID, uuid: UUID().uuidString, type: 3, parent: id, order: Int64(folderPages.count))
            folderPages = children(of: id)
        }
        for (index, appID) in orderedIDs.enumerated() {
            items[appID]?.parent = folderPages[index / 16].id; items[appID]?.order = Int64(index % 16)
        }
    }
    public mutating func reorder(_ id: Int64, before target: Int64) throws {
        guard id != target, apps[id] != nil, apps[target] != nil, isVisible(id), isVisible(target), let parent = items[target]?.parent else { return }
        let oldParent = items[id]!.parent
        if let folder = items[parent]?.parent, items[folder]?.type == 2 {
            var ordered = appIDsInLayoutOrder.filter { self.folder(for: $0) == folder && $0 != id }
            ordered.insert(id, at: ordered.firstIndex(of: target) ?? ordered.count)
            repackFolder(folder, orderedIDs: ordered)
            if oldParent != items[id]?.parent { normalize(oldParent) }
            return
        }
        items[id]?.parent = parent
        var ordered = children(of: parent).filter { $0.id != id }.map(\.id)
        ordered.insert(id, at: ordered.firstIndex(of: target) ?? ordered.count)
        for (index, itemID) in ordered.enumerated() { items[itemID]?.order = Int64(index) }
        if oldParent != parent { normalize(oldParent) }
    }
    public func changes(from old: Layout) -> [String] {
        var result: [String] = []
        for folder in folders where old.items[folder.id] == nil { result.append("新建文件夹「\(name(of: folder.id))」") }
        for page in pages where old.items[page.id] == nil { result.append("新建\(name(of: page.id))") }
        for page in old.pages where items[page.id] == nil { result.append("移除\(old.name(of: page.id))") }
        for folder in old.folders {
            if items[folder.id] == nil { result.append("解散文件夹「\(old.name(of: folder.id))」") }
            else if titles[folder.id] != old.titles[folder.id] { result.append("重命名「\(old.name(of: folder.id))」→「\(name(of: folder.id))」") }
        }
        for app in visibleApps where items[app.id]?.parent != old.items[app.id]?.parent {
            result.append("\(app.title)：\(old.location(of: app.id)) → \(location(of: app.id))")
        }
        let count = items.values.filter { item in old.items[item.id].map { $0.parent == item.parent && $0.order != item.order } ?? false }.count
        if count > 0 { result.append("调整 \(count) 个图标／页面的顺序") }
        return result
    }
    public func validate(against original: Layout) throws {
        guard root == original.root, apps == original.apps else { throw TidyError.message("应用清单发生变化，请重新读取。") }
        guard items[root] == original.items[root] else { throw TidyError.message("不能修改启动台根节点。") }
        for id in original.apps.keys {
            guard let old = original.items[id], let item = items[id], item.type == 4, old.uuid == item.uuid, old.flags == item.flags else { throw TidyError.message("不能修改应用标识或系统标记。") }
        }
        for id in Set(items.keys).subtracting(original.items.keys) {
            guard isVisible(id), items[id]?.type == 2 || items[id]?.type == 3 else { throw TidyError.message("新增容器必须位于可见布局中。") }
        }
        guard Set(visibleApps.map(\.id)) == Set(original.visibleApps.map(\.id)) else { throw TidyError.message("整理不能丢失或隐藏应用。") }
        for item in items.values where isVisible(item.id) && item.id != root {
            guard let parent = items[item.parent] else { throw TidyError.message("布局包含失效的父节点。") }
            let valid = (item.type == 3 && (parent.id == root || parent.type == 2)) || (item.type == 2 && parent.type == 3 && parent.parent == root) || (item.type == 4 && parent.type == 3)
            guard valid else { throw TidyError.message("布局结构不受支持。") }
        }
        for item in original.items.values where !original.isVisible(item.id) {
            guard items[item.id] == item, titles[item.id] == original.titles[item.id] else { throw TidyError.message("不能修改系统内部的隐藏项目。") }
        }
        for id in Set(original.items.keys).subtracting(items.keys) {
            guard let removed = original.items[id], original.isVisible(id), removed.type == 2 || (removed.type == 3 && removed.id != root) else { throw TidyError.message("不能删除应用或系统内部页面。") }
        }
        // Different devices may use different grids. Respect observed capacity, with a 35-slot floor.
        let capacity = max(35, original.pages.map { original.children(of: $0.id).count }.max() ?? 35)
        for page in pages where children(of: page.id).count > capacity {
            throw TidyError.message("\(name(of: page.id))超过 \(capacity) 个图标，请将部分应用移到新页面。")
        }
        let folderCapacity = max(16, original.folders.flatMap { original.children(of: $0.id).map { original.children(of: $0.id).count } }.max() ?? 16)
        for folder in folders {
            guard children(of: folder.id).allSatisfy({ $0.type == 3 }), !(titles[folder.id] ?? "").isEmpty else { throw TidyError.message("文件夹结构或名称无效。") }
            for page in children(of: folder.id) where children(of: page.id).count > folderCapacity {
                throw TidyError.message("「\(name(of: folder.id))」单页超过 \(folderCapacity) 个应用，请分到其他文件夹。")
            }
        }
    }
}

public enum TidyError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public enum Categorizer {
    public static func suggestion(for app: AppRecord) -> String? {
        let text = (app.title + " " + app.bundleID).lowercased()
        let rules: [(String, [String])] = [
            ("开发工具", ["xcode", "vscode", "visual studio", "terminal", "iterm", "docker", "postman", "cursor", "github", "warp", "zed", "codex", "antigravity"]),
            ("AI 助手", ["chatgpt", "claude", "gemini", "copilot", "deepseek", "notebooklm"]),
            ("浏览器", ["safari", "firefox", "chrome", "brave", "microsoft.edgemac", "browser"]),
            ("办公与笔记", ["obsidian", "notion", "office", "excel", "word", "powerpoint", "pages", "numbers", "keynote", "notes", "备忘录", "wps", "飞书"]),
            ("社交通讯", ["wechat", "微信", "qq", "slack", "telegram", "discord", "zoom", "teams", "messages", "facetime", "mail"]),
            ("设计与创作", ["figma", "sketch", "adobe", "affinity", "pixelmator", "finalcut", "final cut", "剪映", "capcut", "blender", "photos", "照片", "preview"]),
            ("影音娱乐", ["music", "spotify", "vlc", "iina", "tv", "网易云", "bilibili", "虎牙", "podcasts", "播客", "quicktime"]),
            ("系统工具", ["com.apple.", "stats", "cleanmymac", "todesk", "keka", "theunarchiver"])
        ]
        return rules.first { _, words in words.contains { text.contains($0) } }?.0
    }
}
