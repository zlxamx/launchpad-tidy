import Foundation

/// Persist only editable layout data. Application bookmarks and credentials stay out of the draft.
public struct DraftSnapshot: Codable {
    public let baselineFingerprint: String
    public let items: [Int64: Item]
    public let titles: [Int64: String]
    public init(draft: Layout, baseline: Layout) {
        baselineFingerprint = baseline.fingerprint; items = draft.items; titles = draft.titles
    }
    public func restore(on current: Layout) throws -> Layout {
        guard current.fingerprint == baselineFingerprint else { throw TidyError.message("发现尚未应用的旧预览，但启动台已发生变化，不能直接恢复。旧预览文件已保留。") }
        var layout = current; layout.items = items; layout.titles = titles
        try layout.validate(against: current)
        return layout
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> DraftSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
