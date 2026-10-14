import XCTest
import LaunchpadCore
@testable import LaunchpadTidy

final class StoreTests: XCTestCase {
    private func fixture() -> LaunchpadCore.Layout {
        var items: [Int64: Item] = [1: .init(id: 1, uuid: "ROOTPAGE", type: 1, parent: 0, order: 0), 2: .init(id: 2, uuid: "PAGE1", type: 3, parent: 1, order: 0), 3: .init(id: 3, uuid: "PAGE2", type: 3, parent: 1, order: 1)]
        var apps: [Int64: AppRecord] = [:]
        for index in 0..<36 {
            let id = Int64(10 + index)
            items[id] = Item(id: id, uuid: "APP\(id)", type: 4, parent: index < 35 ? 2 : 3, order: Int64(index % 35))
            apps[id] = AppRecord(id: id, title: "App\(id)", bundleID: "example.\(id)")
        }
        return LaunchpadCore.Layout(items: items, titles: [:], apps: apps, root: 1, fingerprint: "baseline")
    }
    @MainActor func testFailedMovePreservesSelectionAndPreview() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("draft.json")
        let store = Store(draftURL: path), original = fixture()
        store.baseline = original; store.draft = original; store.selected = [45]
        store.moveSelected(to: 2)
        XCTAssertEqual(store.draft, original)
        XCTAssertEqual(store.selected, [45])
        XCTAssertTrue(store.undoStack.isEmpty)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    @MainActor func testAutosaveUndoAndRedoRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("draft.json"), store = Store(draftURL: path), original = fixture()
        store.baseline = original; store.draft = original
        XCTAssertTrue(store.edit { try $0.move([10], to: 3) })
        let changed = try XCTUnwrap(store.draft)
        let saved = try XCTUnwrap(DraftSnapshot.load(from: path))
        XCTAssertEqual(try saved.restore(on: original), changed)
        store.undo()
        XCTAssertEqual(store.draft, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        store.redo()
        XCTAssertEqual(store.draft, changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }
    @MainActor func testSearchPrunesHiddenSelectionAndBusyBlocksEdits() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("draft.json")
        let store = Store(draftURL: path), original = fixture()
        store.baseline = original; store.draft = original; store.selected = [10,11]
        store.search = "App10"
        XCTAssertEqual(store.selected, [10])
        store.busy = true
        XCTAssertFalse(store.edit { try $0.move([10], to: 3) })
        store.changeScope(.page(3)); store.select(11); store.undo(); store.discard()
        XCTAssertEqual(store.draft, original)
        XCTAssertEqual(store.scope, .all)
        XCTAssertEqual(store.selected, [10])
    }
}
