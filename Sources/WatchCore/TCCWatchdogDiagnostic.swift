import Foundation

public struct TCCWatchdogEvent: Codable, Sendable, Equatable {
    /// Raw local timestamp as emitted by log show.
    public let timestamp: String?
    public let service: String
    public let processID: Int?

    public init(timestamp: String?, service: String, processID: Int?) {
        self.timestamp = timestamp
        self.service = service
        self.processID = processID
    }
}

public enum TCCWatchdogParser {
    private static let servicePattern = try! NSRegularExpression(pattern: #"kTCCService([A-Za-z0-9_]+)"#)
    private static let pidPattern = try! NSRegularExpression(pattern: #"\bpid (\d+)\b"#)
    private static let timestampPattern = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)"#)

    public static func parse(_ text: String) -> [TCCWatchdogEvent] {
        text.split(whereSeparator: \.isNewline).compactMap { substring in
            let line = String(substring)
            guard line.contains("watchdog expired for approval entry"),
                  let service = firstMatch(servicePattern, in: line) else { return nil }
            return TCCWatchdogEvent(
                timestamp: firstMatch(timestampPattern, in: line),
                service: service,
                processID: firstMatch(pidPattern, in: line).flatMap(Int.init)
            )
        }
    }

    private static func firstMatch(_ expression: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let capturedRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capturedRange])
    }
}

/// Passive monitor; never probes TCC-protected folders. Backfills missing intervals
/// after errors/sleep rather than silently reporting healthy on uncovered intervals.
public struct TCCWatchdogDiagnostic: SystemDiagnostic {
    public let id = "tcc-watchdog"
    public let title = "TCC / Sandbox"
    private let runner: any CommandRunning
    public let lookbackMinutes: Int
    public let timeout: TimeInterval
    public let maximumCatchupInterval: TimeInterval

    public init(
        runner: any CommandRunning = BoundedCommandRunner(),
        lookbackMinutes: Int = 3,
        timeout: TimeInterval = 20,
        maximumCatchupInterval: TimeInterval = 86_400
    ) {
        self.runner = runner
        self.lookbackMinutes = max(1, lookbackMinutes)
        self.timeout = timeout
        self.maximumCatchupInterval = max(60, maximumCatchupInterval)
    }

    public func check() -> DiagnosticResult { check(since: nil) }

    public func check(since previousCoverage: Date?, at now: Date = Date()) -> DiagnosticResult {
        let started = Date()
        let recentStart = now.addingTimeInterval(-Double(lookbackMinutes * 60))
        let backfillStart = previousCoverage.map { $0.addingTimeInterval(-2) } ?? recentStart
        let queryStart = min(recentStart, backfillStart)
        guard now.timeIntervalSince(queryStart) <= maximumCatchupInterval else {
            return DiagnosticResult(
                id: id, title: title, health: .unknown,
                summary: "Unverified monitoring gap exceeds backfill limit; start a new baseline",
                eventCount: nil, countsByService: [:],
                elapsedSeconds: Date().timeIntervalSince(started),
                requiresBaselineReset: true
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let predicate = "process == \"kernel\" AND eventMessage CONTAINS[c] \"watchdog expired for approval\" AND eventMessage CONTAINS[c] \"kTCCService\""
        let result = runner.run(
            executable: "/usr/bin/log",
            arguments: ["show", "--start", formatter.string(from: queryStart),
                        "--style", "compact", "--no-pager", "--predicate", predicate],
            timeout: timeout
        )
        let elapsed = Date().timeIntervalSince(started)
        guard !result.timedOut, !result.truncated, result.error == nil, result.exitCode == 0 else {
            let reason: String
            if result.timedOut { reason = "Log query timed out" }
            else if result.truncated { reason = "Log output exceeded the safety limit" }
            else if let error = result.error { reason = error }
            else { reason = "Log query failed (exit \(result.exitCode.map(String.init) ?? "unknown"))" }
            return DiagnosticResult(
                id: id, title: title, health: .unknown,
                summary: reason, eventCount: nil, countsByService: [:], elapsedSeconds: elapsed
            )
        }

        let events = TCCWatchdogParser.parse(result.stdout)
        var services: [String: Int] = [:]
        var pids: [String: Int] = [:]
        for event in events {
            services[event.service, default: 0] += 1
            if let pid = event.processID { pids[String(pid), default: 0] += 1 }
        }
        let ordered = events.sorted { ($0.timestamp ?? "") < ($1.timestamp ?? "") }
        let summary = events.isEmpty
            ? "No watchdog events observed since \(formatter.string(from: queryStart))"
            : "\(events.count) TCC watchdog event\(events.count == 1 ? "" : "s") since \(formatter.string(from: queryStart))"
        return DiagnosticResult(
            id: id, title: title, health: events.isEmpty ? .normal : .warning,
            summary: summary, eventCount: events.count,
            countsByService: services, elapsedSeconds: elapsed,
            countsByPID: pids, firstEvent: ordered.first, lastEvent: ordered.last,
            coverageThrough: now
        )
    }
}
