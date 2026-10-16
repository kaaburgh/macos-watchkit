import AppKit
import Foundation
import SwiftUI
import WatchCore

@MainActor
final class MonitorStore: ObservableObject {
    static let shared = MonitorStore()
    static let pollInterval: TimeInterval = 120
    static let freshnessLimit: TimeInterval = pollInterval * 2.5

    @Published private(set) var history: [MonitorSnapshot]
    @Published private(set) var isChecking = false
    // Explicit published clock: SwiftUI must re-render when a snapshot becomes stale.
    @Published private(set) var clock = Date()

    private let historyStore: HistoryStore
    private var pollTimer: Timer?
    private var freshnessTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var backgroundActivity: NSObjectProtocol?
    private var lastSuccessfulCoverage: Date?
    private var baselineStart: Date
    private static let checkpointKey = "tcc.lastSuccessfulCoverage"
    private static let baselineKey = "tcc.baselineStart"

    var latest: MonitorSnapshot? { history.first }
    var isStale: Bool {
        guard let latest else { return true }
        let age = clock.timeIntervalSince(latest.timestamp)
        return age >= Self.freshnessLimit || age < -Self.freshnessLimit
    }

    var health: DiagnosticHealth {
        guard let latest, !isStale else { return .unknown }
        return latest.health
    }

    var symbol: String {
        if isChecking && latest == nil { return "arrow.triangle.2.circlepath" }
        switch health {
        case .normal: return "checkmark.shield.fill"
        case .warning: return "exclamationmark.shield.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var statusText: String {
        if latest != nil && isStale { return "Last check is stale" }
        switch health {
        case .normal: return "No recent alerts"
        case .warning: return "TCC watchdogs detected"
        case .unknown: return latest == nil ? "Awaiting first check" : "Monitoring unavailable"
        }
    }

    private init(historyStore: HistoryStore = .defaultStore()) {
        let loaded = historyStore.load()
        self.historyStore = historyStore
        self.history = loaded
        self.baselineStart = (UserDefaults.standard.object(forKey: Self.baselineKey) as? Date)
            ?? Date().addingTimeInterval(-180)
        self.lastSuccessfulCoverage = (UserDefaults.standard.object(forKey: Self.checkpointKey) as? Date)
            ?? loaded.flatMap(\.diagnostics).first(where: { $0.id == "tcc-watchdog" && $0.coverageThrough != nil })?.coverageThrough
        UserDefaults.standard.set(baselineStart, forKey: Self.baselineKey)
    }

    func start() {
        guard pollTimer == nil else { return }
        // Background monitoring should not be throttled by App Nap. This does
        // not prevent the Mac itself from going to sleep.
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: .background, reason: "Periodic local TCC watchdog monitoring")
        checkNow()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.checkNow() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        let clockTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.clock = Date() }
        }
        clockTimer.tolerance = 5
        RunLoop.main.add(clockTimer, forMode: .common)
        freshnessTimer = clockTimer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.clock = Date()
                self?.checkNow()
            }
        }
    }

    func checkNow(resetBaseline: Bool = false) {
        guard !isChecking else { return }
        clock = Date()
        isChecking = true
        if resetBaseline {
            // The user explicitly accepts losing earlier unverified coverage.
            baselineStart = Date().addingTimeInterval(-Double(TCCWatchdogDiagnostic().lookbackMinutes * 60))
            UserDefaults.standard.set(baselineStart, forKey: Self.baselineKey)
            lastSuccessfulCoverage = nil
            UserDefaults.standard.removeObject(forKey: Self.checkpointKey)
        }
        let previousCoverage = lastSuccessfulCoverage ?? baselineStart
        // Synchronous subprocess/semaphore waits must not block the Swift-concurrency pool.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = TCCWatchdogDiagnostic().check(since: previousCoverage)
            let snapshot = MonitorSnapshot(timestamp: Date(), diagnostics: [result])
            DispatchQueue.main.async { [weak self] in self?.finish(snapshot) }
        }
    }

    private func finish(_ snapshot: MonitorSnapshot) {
        isChecking = false
        clock = Date()
        if let covered = snapshot.diagnostics.first(where: { $0.id == "tcc-watchdog" })?.coverageThrough {
            lastSuccessfulCoverage = covered
            UserDefaults.standard.set(covered, forKey: Self.checkpointKey)
        }
        history.insert(snapshot, at: 0)
        history = Array(history.prefix(historyStore.limit))
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
        let interval = Int(Self.pollInterval)
        let backfillHours = Int(TCCWatchdogDiagnostic().maximumCatchupInterval / 3600)
        let content = (["macOS WatchKit — last \(records.count) checks",
                        "Polling: \(interval) seconds; adaptive TCC backfill limit: \(backfillHours)h"] + records)
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
