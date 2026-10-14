import XCTest
@testable import LaunchpadCore

private final class AIStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AIOrganizerTests: XCTestCase {
    private func layout(count: Int = 3) -> Layout {
        var items: [Int64: Item] = [1: Item(id: 1, uuid: "ROOTPAGE", type: 1, parent: 0, order: 0), 2: Item(id: 2, uuid: "PAGE", type: 3, parent: 1, order: 0), 3: Item(id: 3, uuid: "HOLDINGPAGE", type: 3, parent: 1, order: 99)]
        var apps: [Int64: AppRecord] = [:]
        for index in 0..<count {
            let id = Int64(10 + index)
            items[id] = Item(id: id, uuid: "APP\(id)", type: 4, parent: 2, order: Int64(index))
            apps[id] = AppRecord(id: id, title: "App\(id)", bundleID: "test.app\(id)", bookmark: Data("PRIVATE_BOOKMARK".utf8))
        }
        items[900] = Item(id: 900, uuid: "HIDDEN", type: 4, parent: 3, order: 0)
        apps[900] = AppRecord(id: 900, title: "隐藏应用", bundleID: "hidden.app")
        return Layout(items: items, titles: [:], apps: apps, root: 1)
    }
    private func client() -> (AIClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIStubProtocol.self]
        let session = URLSession(configuration: config)
        return (AIClient(session: session), session)
    }
    private func response(_ content: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
    }
    private func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    override func tearDown() { AIStubProtocol.handler = nil; super.tearDown() }
    func testEndpointNormalizationAndSecurity() throws {
        XCTAssertEqual(try AIConfiguration(baseURL: "https://example.com/v1/").endpoint().absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(try AIConfiguration(baseURL: "https://example.com/v1/chat/completions").endpoint().absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertNoThrow(try AIConfiguration(baseURL: "http://127.0.0.1:11434/v1").endpoint())
        for url in ["http://example.com/v1", "https://key@example.com/v1", "https://example.com/?key=secret", "file:///tmp"] {
            XCTAssertThrowsError(try AIConfiguration(baseURL: url).endpoint())
        }
    }
    func testExistingConfigurationMigratesWithoutLosingSettings() throws {
        let json = Data("{\"baseURL\":\"https://example.com/v1\",\"model\":\"saved-model\",\"instructions\":\"我的习惯\",\"onlyUngrouped\":true}".utf8)
        let saved = try JSONDecoder().decode(AIConfiguration.self, from: json)
        XCTAssertEqual(saved.model, "saved-model"); XCTAssertTrue(saved.onlyUngrouped); XCTAssertTrue(saved.jsonMode)
        XCTAssertEqual(saved.instructions, "我的习惯")
        XCTAssertThrowsError(try saved.validateCredential(""))
        XCTAssertNoThrow(try AIConfiguration(baseURL: "http://localhost:11434/v1").validateCredential(""))
    }
    func testModelDiscoveryNeverSendsAppInventory() async throws {
        AIStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/models")
            XCTAssertNil(request.httpBody); XCTAssertNil(request.httpBodyStream)
            return (200, Data("{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"},{\"id\":\"a\"}]}".utf8))
        }
        let (client, session) = client(); defer { session.invalidateAndCancel() }
        let models = try await client.availableModels(configuration: .init(baseURL: "https://example.com/v1"), apiKey: "test-key")
        XCTAssertEqual(models, ["a","b"])
    }
    func testOptionalJSONModeAcceptsCodeFenceButKeepsStrictCoverage() async throws {
        let payload = try response("```json\n{\"groups\":[{\"name\":\"工作\",\"app_ids\":[10,11]}],\"unassigned\":[12]}\n```")
        AIStubProtocol.handler = { request in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any])
            XCTAssertNil(json["response_format"])
            return (200, payload)
        }
        let (client, session) = client(); defer { session.invalidateAndCancel() }
        let plan = try await client.organize(layout: layout(), configuration: .init(baseURL: "https://example.com", jsonMode: false), apiKey: "test-key")
        XCTAssertEqual(plan.groups.first?.app_ids, [10,11])
    }
    func testPlanRequiresExactCoverageAndNoDuplicates() throws {
        let allowed: Set<Int64> = [10,11,12]
        let valid = AIPlan(groups: [.init(name: " 办公 ", appIDs: [10,11])], unassigned: [12])
        XCTAssertEqual(try valid.validated(for: allowed).groups.first?.name, "办公")
        for plan in [AIPlan(groups: [.init(name: "办公", appIDs: [10,10])], unassigned: [11,12]), AIPlan(groups: [.init(name: "办公", appIDs: [10,11,999])], unassigned: [12]), AIPlan(groups: [.init(name: "办公", appIDs: [10])], unassigned: [11]), AIPlan(groups: [.init(name: "", appIDs: [10,11])], unassigned: [12]), AIPlan(groups: [.init(name: "办公", appIDs: [10]), .init(name: "办公", appIDs: [11])], unassigned: [12])] {
            XCTAssertThrowsError(try plan.validated(for: allowed))
        }
    }
    func testPreviewPreservesUnknownAndHiddenAppsAndRepaginates() throws {
        let original = layout(count: 35)
        let ids = Set(original.visibleApps.map(\.id))
        let plan = AIPlan(groups: [.init(name: "效率", appIDs: Array(ids.subtracting([10])).sorted())], unassigned: [10])
        let preview = try plan.preview(on: original, candidates: ids)
        XCTAssertEqual(preview.items[10], original.items[10])
        XCTAssertEqual(preview.items[900], original.items[900])
        XCTAssertEqual(preview.apps, original.apps)
        XCTAssertEqual(preview.visibleApps.count, 35)
        let folder = try XCTUnwrap(preview.folders.first)
        XCTAssertEqual(preview.children(of: folder.id).count, 3)
        XCTAssertTrue(preview.children(of: folder.id).allSatisfy { preview.children(of: $0.id).count <= 16 })
        try preview.validate(against: original)
    }
    func testReuseFoldersAndRespectUngroupedScope() throws {
        var original = layout()
        let folder = try original.addFolder(title: "工作", on: 2)
        try original.move([10], to: folder)
        let candidates = Set(AIConfiguration(onlyUngrouped: true).candidates(in: original).map(\.id))
        XCTAssertEqual(candidates, [11,12])
        let preview = try AIPlan(groups: [.init(name: "工作", appIDs: [11])], unassigned: [12]).preview(on: original, candidates: candidates)
        XCTAssertEqual(preview.folders.count, 1)
        XCTAssertEqual(preview.folder(for: 10), folder)
        XCTAssertEqual(preview.folder(for: 11), folder)
        // Its container remains unchanged; closing gaps can renumber its slot.
        XCTAssertEqual(preview.items[12]?.parent, original.items[12]?.parent)
        XCTAssertEqual(preview.items[12]?.uuid, original.items[12]?.uuid)
    }
    func testEmptyFolderCleanupOnlyTouchesEmptiedFolders() throws {
        var original = layout()
        let old = try original.addFolder(title: "旧分类", on: 2)
        let empty = try original.addFolder(title: "手动空文件夹", on: 2)
        try original.move([10], to: old)
        let preview = try AIPlan(groups: [.init(name: "新分类", appIDs: [10,11])], unassigned: [12]).preview(on: original, candidates: [10,11,12])
        XCTAssertNil(preview.items[old])
        XCTAssertNotNil(preview.items[empty])
    }
    func testRequestAndResponseWithMockAPI() async throws {
        let payload = try response("{\"groups\":[{\"name\":\"办公\",\"app_ids\":[10,11]}],\"unassigned\":[12]}")
        AIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = self.body(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "test-model")
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("PRIVATE_BOOKMARK"))
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("hidden.app"))
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-key"))
            return (200, payload)
        }
        let (client, session) = client(); defer { session.invalidateAndCancel() }
        let original = layout()
        let plan = try await client.organize(layout: original, configuration: .init(baseURL: "https://example.com/v1", model: "test-model"), apiKey: "test-key")
        XCTAssertEqual(plan.groups.first?.name, "办公")
        XCTAssertEqual(try plan.preview(on: original, candidates: [10,11,12]).folders.count, 1)
    }
    func testRejectsTruncatedInvalidAndUnauthorizedResponses() async throws {
        let cases = [(401, Data("private error with key".utf8)), (429, Data()), (200, try response("not json")), (200, try response("{}", finish: "length")), (200, try response("{\"groups\":[],\"unassigned\":[10]}"))]
        for (status, payload) in cases {
            AIStubProtocol.handler = { _ in (status, payload) }
            let (client, session) = client(); defer { session.invalidateAndCancel() }
            do {
                _ = try await client.organize(layout: layout(), configuration: .init(baseURL: "https://example.com"), apiKey: "test-key")
                XCTFail("应拒绝无效响应")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private error")); XCTAssertFalse(error.localizedDescription.contains("test-key")) }
        }
    }
    func testCancellationDoesNotReturnAPlan() async throws {
        AIStubProtocol.handler = { _ in throw URLError(.cancelled) }
        let (client, session) = client(); defer { session.invalidateAndCancel() }
        do {
            _ = try await client.organize(layout: layout(), configuration: .init(baseURL: "https://example.com"), apiKey: "test-key")
            XCTFail("应取消请求")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
