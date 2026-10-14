import XCTest
import CSQLite
@testable import LaunchpadCore

final class LaunchpadCoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchpadTidyTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(extraApps: Int = 0) throws -> URL {
        let url = directory.appendingPathComponent("fixture.sqlite")
        let db = try SQLite(url, writable: true, create: true)
        let sql = """
        CREATE TABLE dbinfo(key VARCHAR, value VARCHAR);
        INSERT INTO dbinfo VALUES('launchpad_root','1'),('ignore_items_update_triggers','0');
        CREATE TABLE items(rowid INTEGER PRIMARY KEY ASC,uuid VARCHAR,flags INTEGER,type INTEGER,parent_id INTEGER NOT NULL,ordering INTEGER);
        CREATE TABLE apps(item_id INTEGER PRIMARY KEY,title VARCHAR,bundleid VARCHAR,storeid VARCHAR,category_id INTEGER,moddate REAL,bookmark BLOB);
        CREATE TABLE groups(item_id INTEGER PRIMARY KEY,category_id INTEGER,title VARCHAR);
        CREATE TABLE downloading_apps(item_id INTEGER PRIMARY KEY,title VARCHAR,bundleid VARCHAR);
        CREATE TABLE image_cache(item_id INTEGER,size_big INTEGER,size_mini INTEGER,image_data BLOB,image_data_mini BLOB);
        INSERT INTO items VALUES(1,'ROOTPAGE',NULL,1,0,0),(2,'HOLDINGPAGE',NULL,3,1,99),(3,'PAGE',0,3,1,0),(4,'FOLDER',1,2,3,0),(5,'FOLDERPAGE',0,3,4,0),(6,'PAGE2',0,3,1,1);
        INSERT INTO groups VALUES(1,NULL,NULL),(2,NULL,NULL),(3,NULL,NULL),(4,NULL,'原文件夹'),(5,NULL,NULL),(6,NULL,NULL);
        INSERT INTO items VALUES(10,'A',0,4,3,1),(11,'B',0,4,3,2),(12,'C',0,4,5,0),(13,'HIDDEN',8,4,2,0),(14,'D',0,4,6,0);
        INSERT INTO apps VALUES(10,'Xcode','com.apple.dt.Xcode',NULL,NULL,1,NULL),(11,'微信','com.tencent.xin',NULL,NULL,1,NULL),(12,'备忘录','com.apple.Notes',NULL,NULL,1,NULL),(13,'内部项目','hidden.app',NULL,NULL,1,NULL),(14,'Safari','com.apple.Safari',NULL,NULL,1,NULL);
        CREATE TRIGGER update_items_order BEFORE UPDATE OF ordering ON items WHEN new.ordering > old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers') BEGIN
          UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
          UPDATE items SET ordering=ordering-1 WHERE parent_id=old.parent_id AND ordering BETWEEN old.ordering AND new.ordering;
          UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'; END;
        CREATE TRIGGER update_items_order_backwards BEFORE UPDATE OF ordering ON items WHEN new.ordering < old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers') BEGIN
          UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
          UPDATE items SET ordering=ordering+1 WHERE parent_id=old.parent_id AND ordering BETWEEN new.ordering AND old.ordering;
          UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'; END;
        CREATE TRIGGER update_item_parent AFTER UPDATE OF parent_id ON items WHEN 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers') BEGIN
          UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
          UPDATE items SET ordering=(SELECT ifnull(MAX(ordering),0)+1 FROM items WHERE parent_id=new.parent_id AND rowid!=old.rowid) WHERE rowid=old.rowid;
          UPDATE items SET ordering=ordering-1 WHERE parent_id=old.parent_id AND ordering>old.ordering;
          UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'; END;
        CREATE TRIGGER insert_item AFTER INSERT ON items WHEN 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers') BEGIN
          UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
          UPDATE items SET ordering=(SELECT ifnull(MAX(ordering),0)+1 FROM items WHERE parent_id=new.parent_id) WHERE rowid=new.rowid;
          UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'; END;
        CREATE TRIGGER item_deleted AFTER DELETE ON items BEGIN
          DELETE FROM apps WHERE rowid=old.rowid;
          DELETE FROM groups WHERE item_id=old.rowid;
          DELETE FROM downloading_apps WHERE item_id=old.rowid;
          UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
          UPDATE items SET ordering=ordering-1 WHERE old.parent_id=parent_id AND ordering>old.ordering;
          UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'; END;
        """
        guard sqlite3_exec(db.handle, sql, nil, nil, nil) == SQLITE_OK else { throw db.error() }
        try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
        for index in 0..<extraApps {
            let id = Int64(20 + index)
            try db.execute("INSERT INTO items VALUES(?,?,0,4,6,?)", [.integer(id), .string("APP\(id)"), .integer(Int64(index + 1))])
            try db.execute("INSERT INTO apps(item_id,title,bundleid) VALUES(?,?,?)", [.integer(id), .string("Test\(id)"), .string("test.\(id)")])
        }
        try db.execute("UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'")
        return url
    }
    private var backups: URL { directory.appendingPathComponent("Backups") }

    func testReadExcludesHoldingPage() throws {
        let layout = try LaunchpadDatabase.load(fixture())
        XCTAssertEqual(layout.pages.count, 2)
        XCTAssertEqual(layout.visibleApps.count, 4)
        XCTAssertNil(layout.visibleApps.first { $0.id == 13 })
        XCTAssertEqual(layout.folder(for: 12), 4)
        XCTAssertEqual(layout.location(of: 12), "第 1 页 / 原文件夹")
    }
    func testGlobalFolderSortAndCrossPageDragPreserveCapacity() throws {
        let original = try LaunchpadDatabase.load(fixture(extraApps: 20))
        var draft = original
        let folder = try draft.addFolder(title: "跨页", on: 3)
        let ids = Set(original.visibleApps.map(\.id))
        try draft.move(ids, to: folder)
        // Deliberately reverse names across page boundaries.
        let pageIDs = draft.children(of: folder).map(\.id)
        for id in ids { draft.items[id]?.order = 100 - id }
        draft.sort(container: folder)
        let ordered = draft.appIDsInLayoutOrder.filter { draft.folder(for: $0) == folder }
        let names = ordered.map { draft.name(of: $0) }
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let source = try XCTUnwrap(draft.children(of: pageIDs.last!).first?.id)
        let target = try XCTUnwrap(draft.children(of: pageIDs.first!).first?.id)
        try draft.reorder(source, before: target)
        XCTAssertEqual(draft.appIDsInLayoutOrder.first, source)
        XCTAssertTrue(draft.children(of: folder).allSatisfy { draft.children(of: $0.id).count <= 16 })
        try draft.validate(against: original)
    }
    func testDissolveLargeFolderSpillsToAdditionalPages() throws {
        let original = try LaunchpadDatabase.load(fixture(extraApps: 30))
        var draft = original
        let folder = try draft.addFolder(title: "全部", on: 3)
        try draft.move(Set(original.visibleApps.map(\.id)), to: folder)
        // Fill the page with empty folders so dissolved apps cannot all fit there.
        for index in 0..<10 { _ = try draft.addFolder(title: "空\(index)", on: 3) }
        try draft.dissolveFolder(folder)
        XCTAssertEqual(draft.visibleApps.count, original.visibleApps.count)
        XCTAssertTrue(draft.pages.allSatisfy { draft.children(of: $0.id).count <= 35 })
        try draft.validate(against: original)
    }
    func testDraftSnapshotIsPrivateAndRejectsConflicts() throws {
        let original = try LaunchpadDatabase.load(fixture())
        var draft = original; try draft.move([10], to: 6)
        let path = directory.appendingPathComponent("Drafts/preview.json")
        try DraftSnapshot(draft: draft, baseline: original).save(to: path)
        let saved = try XCTUnwrap(DraftSnapshot.load(from: path))
        XCTAssertEqual(try saved.restore(on: original), draft)
        let json = String(decoding: try Data(contentsOf: path), as: UTF8.self)
        XCTAssertFalse(json.contains("bookmark")); XCTAssertFalse(json.contains("apiKey"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var conflict = original; conflict.fingerprint = "changed"
        XCTAssertThrowsError(try saved.restore(on: conflict))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    func testEmptyPageCleanupPreservesOnePageAndHoldingStorage() throws {
        let original = try LaunchpadDatabase.load(fixture())
        var draft = original
        _ = draft.addPage(); _ = draft.addPage()
        draft.removeEmptyPages()
        XCTAssertEqual(draft.pages.count, original.pages.count)
        XCTAssertEqual(draft.items[2], original.items[2])
        XCTAssertTrue(draft.changes(from: original).isEmpty)
        try draft.validate(against: original)
    }
    func testAIPlanWritesAndRestoresOnDatabaseCopy() throws {
        let url = try fixture(), original = try LaunchpadDatabase.load(url)
        let plan = AIPlan(groups: [.init(name: "工作", appIDs: [10,12]), .init(name: "日常", appIDs: [11,14])], unassigned: [])
        let preview = try plan.preview(on: original, candidates: Set(original.visibleApps.map(\.id)))
        let backup = try LaunchpadDatabase.apply(preview, baseline: original, to: url, backupDirectory: backups)
        let current = try LaunchpadDatabase.load(url)
        XCTAssertEqual(current.inventory, original.inventory)
        XCTAssertEqual(current.items[13], original.items[13])
        XCTAssertEqual(current.folder(for: 10), current.folder(for: 12))
        XCTAssertEqual(current.folder(for: 11), current.folder(for: 14))
        XCTAssertNotEqual(current.folder(for: 10), current.folder(for: 11))
        let restoration = try LaunchpadDatabase.restoration(from: backup, current: current)
        try LaunchpadDatabase.apply(restoration, baseline: current, to: url, backupDirectory: backups)
        XCTAssertEqual(try LaunchpadDatabase.load(url).fingerprint, original.fingerprint)
    }
    func testMoveRenameSortAndRestorePreserveInventory() throws {
        let url = try fixture(), original = try LaunchpadDatabase.load(url)
        var draft = original
        let folder = try draft.addFolder(title: "新分类", on: 6)
        try draft.move([10,11], to: folder)
        try draft.renameFolder(4, to: "我的笔记")
        draft.sort(container: nil)
        let backup = try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups)
        let actual = try LaunchpadDatabase.load(url)
        XCTAssertEqual(actual.inventory, original.inventory)
        XCTAssertEqual(actual.items[13], original.items[13])
        XCTAssertEqual(actual.titles[4], "我的笔记")
        XCTAssertEqual(actual.folders.count, 2)
        XCTAssertEqual(actual.folder(for: 10), actual.folder(for: 11))
        XCTAssertNotNil(actual.folder(for: 10))
        let restored = try LaunchpadDatabase.restoration(from: backup, current: actual)
        try LaunchpadDatabase.apply(restored, baseline: actual, to: url, backupDirectory: backups)
        let final = try LaunchpadDatabase.load(url)
        XCTAssertEqual(final.items, original.items)
        XCTAssertEqual(final.titles, original.titles)
        XCTAssertEqual(final.fingerprint, original.fingerprint)
    }
    func testDissolveAndReorderUnderSystemTriggers() throws {
        let url = try fixture(), original = try LaunchpadDatabase.load(url)
        var draft = original
        try draft.dissolveFolder(4)
        try draft.reorder(14, before: 10)
        let backup = try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups)
        let actual = try LaunchpadDatabase.load(url)
        XCTAssertTrue(actual.folders.isEmpty)
        XCTAssertEqual(actual.items[12]?.parent, 3)
        XCTAssertEqual(actual.children(of: 3).map(\.id), [14,10,11,12])
        let restore = try LaunchpadDatabase.restoration(from: backup, current: actual)
        try LaunchpadDatabase.apply(restore, baseline: actual, to: url, backupDirectory: backups)
        XCTAssertEqual(try LaunchpadDatabase.load(url).fingerprint, original.fingerprint)
    }
    func testConflictAndInvalidDraftNeverWrite() throws {
        let url = try fixture(), original = try LaunchpadDatabase.load(url)
        var draft = original; try draft.move([10], to: 6)
        let db = try SQLite(url, writable: true)
        try db.execute("UPDATE groups SET title='外部修改' WHERE item_id=4")
        let changed = try LaunchpadDatabase.load(url)
        XCTAssertThrowsError(try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups))
        XCTAssertEqual(try LaunchpadDatabase.load(url).fingerprint, changed.fingerprint)
        var invalid = changed; invalid.items.removeValue(forKey: 10)
        XCTAssertThrowsError(try LaunchpadDatabase.apply(invalid, baseline: changed, to: url, backupDirectory: backups))
        XCTAssertEqual(try LaunchpadDatabase.load(url).fingerprint, changed.fingerprint)
    }
    func testFoldersAutomaticallyPaginate() throws {
        let url = try fixture(extraApps: 20), original = try LaunchpadDatabase.load(url)
        var draft = original
        let folder = try draft.addFolder(title: "批量", on: 3)
        try draft.move(Set(original.visibleApps.map(\.id)), to: folder)
        XCTAssertEqual(draft.children(of: folder).count, 2)
        XCTAssertTrue(draft.children(of: folder).allSatisfy { draft.children(of: $0.id).count <= 16 })
        try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups)
        XCTAssertEqual(try LaunchpadDatabase.load(url).visibleApps.count, original.visibleApps.count)
    }
    func testRestoreRejectsChangedApplicationInventory() throws {
        let url = try fixture(), original = try LaunchpadDatabase.load(url)
        var draft = original; try draft.move([10], to: 6)
        let backup = try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups)
        try SQLite(url, writable: true).execute("UPDATE apps SET bundleid='new.app' WHERE item_id=10")
        XCTAssertThrowsError(try LaunchpadDatabase.restoration(from: backup, current: LaunchpadDatabase.load(url)))
    }
    func testWALBackupCanBeReadWithoutSidecars() throws {
        let url = try fixture()
        let writer = try SQLite(url, writable: true)
        try writer.execute("PRAGMA journal_mode=WAL")
        try writer.execute("UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'")
        let original = try LaunchpadDatabase.load(url)
        var draft = original; try draft.move([10], to: 6)
        let backup = try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path + "-shm"))
        XCTAssertEqual(try LaunchpadDatabase.load(backup).fingerprint, original.fingerprint)
        withExtendedLifetime(writer) {}
    }
    func testExpiredDeadlineRollsBack() throws {
        let url = try fixture(), original = try LaunchpadDatabase.load(url)
        var draft = original; try draft.move([10], to: 6)
        XCTAssertThrowsError(try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups, deadline: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(try LaunchpadDatabase.load(url).fingerprint, original.fingerprint)
    }
    func testTransactionRollsBackOnSQLFailure() throws {
        let url = try fixture()
        try SQLite(url, writable: true).execute("CREATE TRIGGER reject_move BEFORE UPDATE OF parent_id ON items WHEN NEW.rowid=10 BEGIN SELECT RAISE(ABORT,'test failure'); END")
        let original = try LaunchpadDatabase.load(url)
        var draft = original; try draft.move([10], to: 6)
        XCTAssertThrowsError(try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups))
        XCTAssertEqual(try LaunchpadDatabase.load(url).fingerprint, original.fingerprint)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: backups.path)).count, 1)
    }
    func testRealDatabaseCopyRoundTripWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["LAUNCHPAD_TEST_DATABASE"] else { throw XCTSkip("提供数据库副本时执行真实结构测试") }
        let url = directory.appendingPathComponent("real-copy.sqlite")
        try FileManager.default.copyItem(atPath: path, toPath: url.path)
        let original = try LaunchpadDatabase.load(url)
        guard let first = original.visibleApps.first, let page = original.pages.last else { return XCTFail("副本没有可见应用或页面") }
        var draft = original
        let folder = try draft.addFolder(title: "测试临时分类", on: page.id)
        try draft.move([first.id], to: folder)
        draft.sort(container: folder)
        let backup = try LaunchpadDatabase.apply(draft, baseline: original, to: url, backupDirectory: backups)
        let current = try LaunchpadDatabase.load(url)
        XCTAssertEqual(current.inventory, original.inventory)
        let restoration = try LaunchpadDatabase.restoration(from: backup, current: current)
        try LaunchpadDatabase.apply(restoration, baseline: current, to: url, backupDirectory: backups)
        XCTAssertEqual(try LaunchpadDatabase.load(url).fingerprint, original.fingerprint)
    }
}
