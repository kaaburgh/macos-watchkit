import AppKit
import Foundation
import SwiftUI
import WatchCore

@MainActor
final class MonitorStore: ObservableObject {
    static let shared = MonitorStore()
    static let pollInterval: TimeInterval = 120

    @Published private(set) var history: [MonitorSnapshot]
    @Published private(set) var isChecking = false

    private let historyStore: HistoryStore
    private var timer: Timer?
    private var lastSuccessfulCoverage: Date?
    private let checkpointKey = "tcc.lastSuccessfulCoverage"

    var latest: MonitorSnapshot? { history.first }
    var needsBaselineReset: Bool {
        latest?.diagnostics.contains(where: { $0.requiresBaselineReset == true }) == true
    }
    /// A persisted snapshot must never be presented as current health after a long pause or relaunch.
    var health: DiagnosticHealth {
        guard let latest, Date().timeIntervalSince(latest.timestamp) < 300 else { return .unknown }
        return latest.health
    }

    var symbol: String {
        if isChecking && latest == nil { return "arrow.triangle.2.circlepath" }
        switch health {
        case .normal: return "checkmark.shield.fill"
        case .warning: return "exclamationmark.shield.fill"
        case .unknown: return "questionmark.shield.fill"
        }
    }

    var statusText: String {
        if let latest, Date().timeIntervalSince(latest.timestamp) >= 300 {
            return "Last check is stale"
        }
        switch health {
        case .normal: return "No recent alerts"
        case .warning: return "TCC watchdogs detected"
        case .unknown: return latest == nil ? "Awaiting first check" : "Monitoring unavailable"
        }
    }

    private init(historyStore: HistoryStore = .defaultStore()) {
        self.historyStore = historyStore
        self.history = historyStore.load()
        self.lastSuccessfulCoverage = (UserDefaults.standard.object(forKey: checkpointKey) as? Date)
            ?? history.flatMap(\.diagnostics).first(where: { $0.id == "tcc-watchdog" && $0.coverageThrough != nil })?.coverageThrough
    }

    func start() {
        guard timer == nil else { return }
        checkNow()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in MonitorStore.shared.checkNow() }
        }
    }

    func checkNow(resetBaseline: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        // Persisted independently of the 100-entry history, even after prolonged failures.
        let previousCoverage: Date? = resetBaseline ? nil : lastSuccessfulCoverage
        Task.detached(priority: .utility) {
            // Add more independent SystemDiagnostic implementations here later.
            let result = TCCWatchdogDiagnostic().check(since: previousCoverage)
            let snapshot = MonitorSnapshot(timestamp: Date(), diagnostics: [result])
            await MainActor.run {
                MonitorStore.shared.finish(snapshot)
            }
        }
    }

    private func finish(_ snapshot: MonitorSnapshot) {
        isChecking = false
        if let coveredThrough = snapshot.diagnostics.first(where: { $0.id == "tcc-watchdog" })?.coverageThrough {
            lastSuccessfulCoverage = coveredThrough
            UserDefaults.standard.set(coveredThrough, forKey: checkpointKey)
        }
        history.insert(snapshot, at: 0)
        history = Array(history.prefix(100))
        historyStore.save(history)
    }

    func copyReport() {
        let records = history.prefix(12).map { snapshot in
            let results = snapshot.diagnostics.map { diagnostic in
                let services = diagnostic.countsByService.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                let pids = (diagnostic.countsByPID ?? [:]).sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                let first = diagnostic.firstEvent.map { "first=\($0.timestamp ?? "?") pid=\($0.processID.map(String.init) ?? "?")" } ?? ""
                let last = diagnostic.lastEvent.map { "last=\($0.timestamp ?? "?") pid=\($0.processID.map(String.init) ?? "?")" } ?? ""
                let reset = diagnostic.requiresBaselineReset == true ? "BASELINE RESET REQUIRED" : ""
                return "\(diagnostic.title): \(diagnostic.health.rawValue); \(diagnostic.summary); services=[\(services)] pids=[\(pids)] \(first) \(last) \(reset)"
            }.joined(separator: " | ")
            return "\(ISO8601DateFormatter().string(from: snapshot.timestamp)) \(results)"
        }
        let content = (["macOS WatchKit — last \(records.count) checks", "Polling: 120 seconds; adaptive TCC coverage with 24h backfill limit"] + records).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    func revealHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([historyStore.fileURL])
    }
}
