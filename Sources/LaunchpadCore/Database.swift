import Foundation
import CryptoKit
import CSQLite

enum SQLValue {
    case integer(Int64), string(String), null
}

final class SQLite {
    var handle: OpaquePointer?
    init(_ url: URL, writable: Bool = false, create: Bool = false) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) : SQLITE_OPEN_READONLY
        let code = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle); handle = nil
            throw TidyError.message("读取启动台失败：\(detail)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try query(sql, values) { _ in }
    }
    func query(_ sql: String, _ values: [SQLValue] = [], row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw TidyError.message("\(error().localizedDescription)（准备：\(sql)）") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let code: Int32
            switch value {
            case let .integer(number): code = sqlite3_bind_int64(statement, Int32(index + 1), number)
            case let .string(text): code = sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            case .null: code = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard code == SQLITE_OK else { throw error() }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw TidyError.message("\(error().localizedDescription)（\(sql)）") }
            try row(statement)
        }
    }
    func error() -> TidyError { .message("启动台数据库：\(String(cString: sqlite3_errmsg(handle)))") }
    func backup(to url: URL) throws {
        let destination = try SQLite(url, writable: true, create: true)
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else { throw TidyError.message("备份初始化：\(destination.error().localizedDescription)") }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw TidyError.message("备份复制：\(destination.error().localizedDescription)（\(step)/\(finish)）") }
        // A standalone snapshot must not rely on absent -wal/-shm sidecars.
        // Apple's SQLite cannot initialize a copied WAL database through a read-only connection.
        // Reopen: backup may copy WAL header bytes while the destination pager
        // still believes it is in DELETE mode. Reopening makes the mode switch real.
        guard sqlite3_close(destination.handle) == SQLITE_OK else { throw destination.error() }
        destination.handle = nil
        let standalone = try SQLite(url, writable: true)
        try standalone.execute("PRAGMA journal_mode=DELETE")
        var valid = true
        try standalone.query("PRAGMA quick_check") { if SQLite.text($0, 0) != "ok" { valid = false } }
        guard valid else { throw TidyError.message("备份完整性检查失败。") }
        guard sqlite3_close(standalone.handle) == SQLITE_OK else { throw standalone.error() }
        standalone.handle = nil
        // SQLite on macOS can leave an unused shared-memory sidecar after leaving WAL.
        // This is our newly-created, closed snapshot, never the live source database.
        let sidecar = URL(fileURLWithPath: url.path + "-shm")
        if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
    }
    func signature(_ queries: [String]) throws -> String {
        var rows: [[String]] = []
        for sql in queries {
            rows.append([sql])
            try query(sql) { statement in
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_NULL: return "null"
                    case SQLITE_BLOB:
                        guard let pointer = sqlite3_column_blob(statement, column) else { return "blob:" }
                        return "blob:" + Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column))).base64EncodedString()
                    default: return "value:" + SQLite.text(statement, column)
                    }
                })
            }
        }
        return SHA256.hash(data: try JSONEncoder().encode(rows)).map { String(format: "%02x", $0) }.joined()
    }
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    func readLayout() throws -> Layout {
        for (table, required) in ["items": ["rowid", "uuid", "flags", "type", "parent_id", "ordering"], "apps": ["item_id", "title", "bundleid", "bookmark"], "groups": ["item_id", "title", "category_id"]] {
            var columns = Set<String>()
            try query("PRAGMA table_info(\(table))") { columns.insert(SQLite.text($0, 1)) }
            guard Set(required).isSubset(of: columns) else { throw TidyError.message("此版本的启动台数据库结构暂不支持。") }
        }
        var root: Int64 = 0
        var triggerState = ""
        try query("SELECT key,value FROM dbinfo WHERE key IN ('launchpad_root','ignore_items_update_triggers')") {
            if SQLite.text($0, 0) == "launchpad_root" { root = Int64(SQLite.text($0, 1)) ?? 0 }
            else { triggerState = SQLite.text($0, 1) }
        }
        guard root > 0, triggerState == "0" else { throw TidyError.message("启动台正在更新，或数据库状态不受支持，请稍后重新读取。") }
        var items: [Int64: Item] = [:]
        try query("SELECT rowid,uuid,flags,type,parent_id,ordering FROM items") { statement in
            let id = sqlite3_column_int64(statement, 0)
            items[id] = Item(id: id, uuid: SQLite.text(statement, 1), flags: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2), type: sqlite3_column_int64(statement, 3), parent: sqlite3_column_int64(statement, 4), order: sqlite3_column_int64(statement, 5))
        }
        guard items[root]?.type == 1, items.values.allSatisfy({ [1, 2, 3, 4].contains($0.type) }) else { throw TidyError.message("发现下载中或不支持的启动台项目，请完成下载后重试。") }
        var apps: [Int64: AppRecord] = [:]
        try query("SELECT item_id,title,bundleid,bookmark FROM apps") { statement in
            let id = sqlite3_column_int64(statement, 0)
            let bookmark = sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 3))) }
            apps[id] = AppRecord(id: id, title: SQLite.text(statement, 1), bundleID: SQLite.text(statement, 2), bookmark: bookmark)
        }
        var titles: [Int64: String] = [:]
        try query("SELECT item_id,title FROM groups WHERE title IS NOT NULL") { titles[sqlite3_column_int64($0, 0)] = SQLite.text($0, 1) }
        let inventoryQueries = ["SELECT * FROM apps ORDER BY item_id", "SELECT * FROM downloading_apps ORDER BY item_id"]
        let inventory = try signature(inventoryQueries)
        let fingerprint = try signature(inventoryQueries + ["SELECT * FROM items ORDER BY rowid", "SELECT * FROM groups ORDER BY item_id", "SELECT * FROM dbinfo ORDER BY key"])
        return Layout(items: items, titles: titles, apps: apps, root: root, fingerprint: fingerprint, inventory: inventory)
    }
}

public enum LaunchpadDatabase {
    public static func locate() throws -> URL {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/getconf"); task.arguments = ["DARWIN_USER_DIR"]
        let pipe = Pipe(); task.standardOutput = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0, let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { throw TidyError.message("无法找到当前用户的启动台目录。") }
        let url = URL(fileURLWithPath: path).appendingPathComponent("com.apple.dock.launchpad/db/db")
        guard FileManager.default.fileExists(atPath: url.path) else { throw TidyError.message("未找到传统启动台数据库。请先打开一次启动台；新版 macOS 的 Spotlight 应用列表暂不支持整理。") }
        return url
    }
    public static func load(_ url: URL) throws -> Layout {
        let db = try SQLite(url)
        try db.execute("BEGIN")
        let layout = try db.readLayout()
        try db.execute("COMMIT")
        return layout
    }
    /// The caller must suspend Dock before using this on the system database.
    /// Tests use disposable database copies only.
    @discardableResult public static func apply(_ draft: Layout, baseline: Layout, to url: URL, backupDirectory: URL, deadline: Date? = nil) throws -> URL {
        try draft.validate(against: baseline)
        let db = try SQLite(url, writable: true)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }
        let current = try db.readLayout()
        guard current.fingerprint == baseline.fingerprint else { throw TidyError.message("启动台已被系统或其他操作修改。请重新读取后再整理。") }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "Launchpad-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).sqlite"
        let backupURL = backupDirectory.appendingPathComponent(name)
        let pendingURL = backupDirectory.appendingPathComponent(name + ".pending")
        // A second read connection sees the committed baseline while this connection holds the writer lock.
        try SQLite(url).backup(to: pendingURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
        let saved = try load(pendingURL)
        guard saved.fingerprint == current.fingerprint else { throw TidyError.message("备份校验未通过，已取消应用。") }
        try FileManager.default.moveItem(at: pendingURL, to: backupURL)
        try checkDeadline(deadline)
        try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
        var mapped: [Int64: Int64] = [:]
        var next = (current.items.keys.max() ?? 0) + 1
        for id in draft.items.keys.sorted() where id < 0 { mapped[id] = next; next += 1 }
        func real(_ id: Int64) -> Int64 { mapped[id] ?? id }
        for item in draft.items.values where current.items[item.id] == nil {
            guard item.type == 2 || item.type == 3 else { throw TidyError.message("不能新增系统应用记录。") }
            try db.execute("INSERT INTO items(rowid,uuid,flags,type,parent_id,ordering) VALUES(?,?,?,?,?,?)", [.integer(real(item.id)), .string(item.uuid), item.flags.map(SQLValue.integer) ?? .null, .integer(item.type), .integer(real(item.parent)), .integer(item.order)])
            try db.execute("INSERT INTO groups(item_id,category_id,title) VALUES(?,NULL,?)", [.integer(real(item.id)), draft.titles[item.id].map(SQLValue.string) ?? .null])
        }
        // Move children before deleting containers. The system's deletion trigger resets its ignore flag.
        for item in draft.items.values where current.items[item.id]?.parent != item.parent {
            try db.execute("UPDATE items SET parent_id=? WHERE rowid=?", [.integer(real(item.parent)), .integer(real(item.id))])
        }
        let removed = current.items.values.filter { draft.items[$0.id] == nil }.sorted { $0.type == $1.type ? $0.id < $1.id : $0.type > $1.type }
        for item in removed {
            try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
            try db.execute("DELETE FROM items WHERE rowid=?", [.integer(item.id)])
        }
        try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
        for item in draft.items.values {
            try db.execute("UPDATE items SET uuid=?,flags=?,type=?,parent_id=?,ordering=? WHERE rowid=?", [.string(item.uuid), item.flags.map(SQLValue.integer) ?? .null, .integer(item.type), .integer(real(item.parent)), .integer(item.order), .integer(real(item.id))])
            if item.type == 2 { try db.execute("UPDATE groups SET title=? WHERE item_id=?", [draft.titles[item.id].map(SQLValue.string) ?? .null, .integer(real(item.id))]) }
        }
        try db.execute("UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'")
        let actual = try db.readLayout()
        guard actual.inventory == current.inventory else { throw TidyError.message("应用清单校验失败，修改已回滚。") }
        guard actual.items.count == draft.items.count else { throw TidyError.message("布局数量校验失败，修改已回滚。") }
        for item in draft.items.values {
            var expected = item; expected.id = real(item.id); expected.parent = real(item.parent)
            guard actual.items[expected.id] == expected else { throw TidyError.message("布局写入校验失败，修改已回滚。") }
        }
        for folder in draft.folders where actual.titles[real(folder.id)] != draft.titles[folder.id] { throw TidyError.message("文件夹名称校验失败，修改已回滚。") }
        var foreignKeysValid = true
        try db.query("PRAGMA foreign_key_check") { _ in foreignKeysValid = false }
        guard foreignKeysValid else { throw TidyError.message("布局引用检查失败，修改已回滚。") }
        try checkDeadline(deadline)
        try db.execute("COMMIT"); committed = true
        return backupURL
    }
    private static func checkDeadline(_ deadline: Date?) throws {
        if let deadline, Date() >= deadline { throw TidyError.message("应用布局超时，已取消写入。请稍后重试。") }
    }
    public static func restoration(from backup: URL, current: Layout) throws -> Layout {
        let old = try load(backup)
        guard old.inventory == current.inventory else { throw TidyError.message("备份后应用清单发生过变化，不能直接恢复此备份。请选择更新的备份。") }
        try old.validate(against: current)
        return old
    }
}
