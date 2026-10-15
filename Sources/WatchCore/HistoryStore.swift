import Foundation

public struct HistoryStore {
    public let fileURL: URL
    public let limit: Int

    public init(fileURL: URL, limit: Int = 100) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public static func defaultStore() -> HistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStore(fileURL: base.appendingPathComponent("macos-watchkit/history.json"))
    }

    public func load() -> [MonitorSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshots = try? JSONDecoder().decode([MonitorSnapshot].self, from: data) else { return [] }
        return Array(snapshots.prefix(limit))
    }

    public func save(_ snapshots: [MonitorSnapshot]) {
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(snapshots.prefix(limit)))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Monitoring must continue even if the local history cannot be persisted.
        }
    }
}
