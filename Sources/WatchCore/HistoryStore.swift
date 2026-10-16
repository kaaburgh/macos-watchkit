import Foundation

public struct HistoryStore {
    public let fileURL: URL
    public let limit: Int

    public init(fileURL: URL, limit: Int = 100) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
    }

    public static func defaultStore() -> HistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStore(fileURL: base.appendingPathComponent("macos-watchkit/history.json"))
    }

    public func load() -> [MonitorSnapshot] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return Array(try JSONDecoder().decode([MonitorSnapshot].self, from: Data(contentsOf: fileURL)).prefix(limit))
        } catch {
            // Never overwrite unparseable history with a fresh, empty array.
            preserveUnreadableFile()
            return []
        }
    }

    public func save(_ snapshots: [MonitorSnapshot]) {
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Handles an unreadable file that appeared after load(), too.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                if (try? JSONDecoder().decode([MonitorSnapshot].self, from: data)) == nil {
                    guard preserveUnreadableFile() else { return }
                }
            }
            let data = try JSONEncoder().encode(Array(snapshots.prefix(limit)))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("macOS WatchKit: history not saved: %@", String(describing: error))
        }
    }

    @discardableResult
    private func preserveUnreadableFile() -> Bool {
        let destination = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            NSLog("macOS WatchKit: preserved unreadable history at %@", destination.path)
            return true
        } catch {
            NSLog("macOS WatchKit: could not preserve unreadable history: %@", String(describing: error))
            return false
        }
    }
}
