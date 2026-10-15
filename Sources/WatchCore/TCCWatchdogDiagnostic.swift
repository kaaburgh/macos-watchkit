import Foundation

public struct TCCWatchdogEvent: Equatable {
    public let service: String
    public let processID: Int?
}

public enum TCCWatchdogParser {
    private static let servicePattern = try! NSRegularExpression(pattern: #"kTCCService([A-Za-z0-9_]+)"#)
    private static let pidPattern = try! NSRegularExpression(pattern: #"\bpid (\d+)\b"#)

    public static func parse(_ text: String) -> [TCCWatchdogEvent] {
        text.split(whereSeparator: \.isNewline).compactMap { substring in
            let line = String(substring)
            guard line.contains("watchdog expired for approval entry"),
                  let service = firstMatch(servicePattern, in: line) else { return nil }
            return TCCWatchdogEvent(service: service, processID: firstMatch(pidPattern, in: line).flatMap(Int.init))
        }
    }

    private static func firstMatch(_ expression: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let capturedRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capturedRange])
    }
}

/// Passive detection only: never touches Desktop, Documents, or Downloads, and never requests TCC access.
/// A successful query with zero matches means "no observed watchdogs", not "TCC is definitely healthy".
public struct TCCWatchdogDiagnostic: SystemDiagnostic {
    public let id = "tcc-watchdog"
    public let title = "TCC / Sandbox"
    private let runner: any CommandRunning
    public let lookbackMinutes: Int
    public let timeout: TimeInterval

    public init(
        runner: any CommandRunning = BoundedCommandRunner(),
        lookbackMinutes: Int = 3,
        timeout: TimeInterval = 20
    ) {
        self.runner = runner
        self.lookbackMinutes = lookbackMinutes
        self.timeout = timeout
    }

    public func check() -> DiagnosticResult {
        let start = Date()
        let predicate = "process == \"kernel\" AND eventMessage CONTAINS[c] \"watchdog expired for approval\" AND eventMessage CONTAINS[c] \"kTCCService\""
        let result = runner.run(
            executable: "/usr/bin/log",
            arguments: ["show", "--last", "\(lookbackMinutes)m", "--style", "compact", "--no-pager", "--predicate", predicate],
            timeout: timeout
        )
        let elapsed = Date().timeIntervalSince(start)

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
        for event in events { services[event.service, default: 0] += 1 }
        let summary = events.isEmpty
            ? "No watchdog events observed in the last \(lookbackMinutes) min"
            : "\(events.count) TCC watchdog event\(events.count == 1 ? "" : "s") in the last \(lookbackMinutes) min"
        return DiagnosticResult(
            id: id, title: title, health: events.isEmpty ? .normal : .warning,
            summary: summary, eventCount: events.count,
            countsByService: services, elapsedSeconds: elapsed
        )
    }
}
