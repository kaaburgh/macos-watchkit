import Foundation

public struct TCCWatchdogEvent: Codable, Sendable, Equatable {
    public let timestamp: String?
    public let service: String
    public let processID: Int?
    public let approvalEntryID: String?

    public init(timestamp: String?, service: String, processID: Int?, approvalEntryID: String? = nil) {
        self.timestamp = timestamp
        self.service = service
        self.processID = processID
        self.approvalEntryID = approvalEntryID
    }

    var identity: String {
        // Approval-entry identifiers are unique for watchdog requests; use all parsed fields as fallback.
        if let approvalEntryID { return "entry:\(approvalEntryID)" }
        return "\(timestamp ?? "?")|\(service)|\(processID.map(String.init) ?? "?")"
    }
}

public enum TCCWatchdogParser {
    private static let servicePattern = try! NSRegularExpression(pattern: #"kTCCService([A-Za-z0-9_]+)"#, options: .caseInsensitive)
    private static let pidPattern = try! NSRegularExpression(pattern: #"\bpid\s+(\d+)\b"#, options: .caseInsensitive)
    private static let entryPattern = try! NSRegularExpression(pattern: #"\bentry\s+(\d+)\b"#, options: .caseInsensitive)
    private static let timestampPattern = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)"#)

    public static func parse(_ text: String) -> [TCCWatchdogEvent] {
        text.split(whereSeparator: \.isNewline).compactMap { part in
            let line = String(part)
            // The same case-insensitive phrase as the log predicate. If the service is
            // unrecognized, retain the event as Unclassified: never give a false green.
            guard line.range(of: "watchdog expired for approval", options: .caseInsensitive) != nil else { return nil }
            return TCCWatchdogEvent(
                timestamp: firstMatch(timestampPattern, in: line),
                service: firstMatch(servicePattern, in: line) ?? "Unclassified",
                processID: firstMatch(pidPattern, in: line).flatMap(Int.init),
                approvalEntryID: firstMatch(entryPattern, in: line)
            )
        }
    }

    private static func firstMatch(_ expression: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

/// Formats absolute instants for log(1), including the offset during repeated DST hours.
enum TCCLogDateFormatter {
    static func make(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return formatter
    }
}

/// Passive log-only diagnostic. Processes bounded, explicitly-ended intervals. Successfully
/// checked intervals advance a persisted checkpoint even when later chunks fail; unread gaps
/// are never reported healthy. A failing chunk is subdivided to make progress through storms.
public struct TCCWatchdogDiagnostic: SystemDiagnostic {
    public let id = "tcc-watchdog"
    public let title = "TCC / Sandbox"
    private let runner: any CommandRunning
    public let lookbackMinutes: Int
    public let timeout: TimeInterval
    public let maximumCatchupInterval: TimeInterval
    public let chunkDuration: TimeInterval
    public let minimumChunkDuration: TimeInterval
    public let maximumChunkAttempts: Int
    public let maximumSuccessfulChunks: Int

    public init(
        runner: any CommandRunning = BoundedCommandRunner(),
        lookbackMinutes: Int = 3,
        timeout: TimeInterval = 20,
        maximumCatchupInterval: TimeInterval = 86_400,
        chunkDuration: TimeInterval = 600,
        minimumChunkDuration: TimeInterval = 30,
        maximumChunkAttempts: Int = 16,
        maximumSuccessfulChunks: Int = 8
    ) {
        self.runner = runner
        self.lookbackMinutes = max(1, lookbackMinutes)
        self.timeout = timeout
        self.maximumCatchupInterval = max(60, maximumCatchupInterval)
        self.chunkDuration = max(1, chunkDuration)
        self.minimumChunkDuration = max(1, min(minimumChunkDuration, chunkDuration))
        self.maximumChunkAttempts = max(1, maximumChunkAttempts)
        self.maximumSuccessfulChunks = max(1, maximumSuccessfulChunks)
    }

    public func check() -> DiagnosticResult { check(since: nil) }

    public func check(since previousCoverage: Date?, at now: Date = Date()) -> DiagnosticResult {
        let started = Date()
        let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let recentStart = end.addingTimeInterval(-Double(lookbackMinutes * 60))
        let historicalStart = min(recentStart, previousCoverage.map { $0.addingTimeInterval(-2) } ?? recentStart)
        // Large offline gaps remain unverified, but must not prevent detection
        // of a *current* TCC watchdog storm.
        let historicalGapUnverified = end.timeIntervalSince(historicalStart) > maximumCatchupInterval
        let start = historicalGapUnverified ? recentStart : historicalStart

        let formatter = TCCLogDateFormatter.make()
        let predicate = "process == \"kernel\" AND eventMessage CONTAINS[c] \"watchdog expired for approval\""

        var cursor = start
        var coveredThrough: Date?
        var chunkSeconds = chunkDuration
        var attempts = 0
        var successes = 0
        var seen = Set<String>()
        var events: [TCCWatchdogEvent] = []
        var failure: String?
        var minimumSizeFailure = false

        while cursor < end && attempts < maximumChunkAttempts && successes < maximumSuccessfulChunks {
            attempts += 1
            let chunkEnd = min(end, cursor.addingTimeInterval(chunkSeconds))
            let result = runner.run(
                executable: "/usr/bin/log",
                arguments: ["show", "--start", formatter.string(from: cursor),
                            "--end", formatter.string(from: chunkEnd),
                            "--style", "compact", "--no-pager", "--predicate", predicate],
                timeout: timeout
            )
            // Partial output may already prove there is a TCC failure; preserve those
            // events for a warning even when the chunk's coverage cannot be trusted.
            for event in TCCWatchdogParser.parse(result.stdout) {
                if seen.insert(event.identity).inserted { events.append(event) }
            }
            let complete = !result.timedOut && !result.truncated && result.error == nil && result.exitCode == 0
            if complete {
                successes += 1
                coveredThrough = chunkEnd
                cursor = chunkEnd
                chunkSeconds = chunkDuration
                failure = nil
            } else {
                if result.timedOut { failure = "Log query timed out" }
                else if result.truncated { failure = "Log output exceeded the safety limit" }
                else if let error = result.error { failure = error }
                else { failure = "Log query failed (exit \(result.exitCode.map(String.init) ?? "unknown"))" }
                // Only window-size failures can benefit from bisection. A nonzero
                // exit or launch error is not fixed by querying a shorter interval;
                // keep the gap unknown without offering a misleading baseline reset.
                guard result.timedOut || result.truncated else { break }
                if chunkEnd.timeIntervalSince(cursor) <= minimumChunkDuration {
                    minimumSizeFailure = true
                    break
                }
                chunkSeconds = max(minimumChunkDuration, floor(chunkEnd.timeIntervalSince(cursor) / 2))
            }
        }

        let complete = cursor >= end
        let elapsed = Date().timeIntervalSince(started)
        let services = Dictionary(events.map { ($0.service, 1) }, uniquingKeysWith: +)
        let pids = Dictionary(events.compactMap { $0.processID.map { (String($0), 1) } }, uniquingKeysWith: +)
        let sorted = events.sorted { ($0.timestamp ?? "") < ($1.timestamp ?? "") }
        let count = events.count
        let reason = failure ?? "Backfill in progress"
        let summary: String
        if count > 0 {
            summary = "At least \(count) TCC watchdog event\(count == 1 ? "" : "s")" +
                (historicalGapUnverified ? " (recent window; older monitoring gap unverified)" :
                    (complete ? "" : " (partial coverage: \(reason))"))
        } else if historicalGapUnverified {
            summary = complete
                ? "No recent watchdog events observed; older monitoring gap unverified (start a new baseline)"
                : "\(reason); recent window incomplete and older monitoring gap unverified"
        } else if complete {
            summary = "No watchdog events observed since \(formatter.string(from: start))"
        } else {
            summary = "\(reason); unverified gap after \(formatter.string(from: cursor))"
        }
        let requiresReset = historicalGapUnverified || (!complete && minimumSizeFailure)
        return DiagnosticResult(
            id: id, title: title,
            health: count > 0 ? .warning : (complete && !historicalGapUnverified ? .normal : .unknown),
            summary: summary, eventCount: complete || count > 0 ? count : nil,
            countsByService: services, elapsedSeconds: elapsed,
            countsByPID: pids, firstEvent: sorted.first, lastEvent: sorted.last,
            // A recent successful query cannot certify an older skipped interval.
            coverageThrough: historicalGapUnverified ? nil : coveredThrough,
            requiresBaselineReset: requiresReset ? true : nil
        )
    }
}
