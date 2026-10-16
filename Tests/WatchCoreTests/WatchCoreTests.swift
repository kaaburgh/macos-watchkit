import Foundation
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import WatchCore

private final class RecordedCall {
    var arguments: [String] = []
}

private struct FakeRunner: CommandRunning {
    let result: CommandResult
    var recorder: RecordedCall? = nil
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        recorder?.arguments = arguments
        return result
    }
}

private final class SequencedRunner: CommandRunning {
    var results: [CommandResult]
    private(set) var calls: [[String]] = []
    init(_ results: [CommandResult]) { self.results = results }
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls.append(arguments)
        return results.isEmpty ? CommandResult(stdout: "") : results.removeFirst()
    }
}

final class WatchCoreTests: XCTestCase {
    private let example = """
    Timestamp               Ty Process[PID:TID]
    2026-10-12 18:24:55.024 Df kernel[0:3d8b] (Sandbox) watchdog expired for approval entry 3174168 (kTCCServiceSystemPolicyDownloadsFolder, pid 85402)
    2026-10-12 18:25:00.024 Df kernel[0:3d8b] (Sandbox) watchdog expired for approval entry 3174169 (kTCCServiceSystemPolicyDocumentsFolder, pid 85401)
    2026-10-12 18:25:01.024 Df kernel[0:3d8b] informational message unrelated to watchdog
    """

    func testParseEventsServicesPIDAndTimes() {
        let events = TCCWatchdogParser.parse(example)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.service), ["SystemPolicyDownloadsFolder", "SystemPolicyDocumentsFolder"])
        XCTAssertEqual(events.map(\.processID), [85402, 85401])
        XCTAssertEqual(events.map(\.timestamp), ["2026-10-12 18:24:55.024", "2026-10-12 18:25:00.024"])
    }

    func testNoEventsIsNormalButQualified() {
        let result = TCCWatchdogDiagnostic(runner: FakeRunner(result: CommandResult(stdout: "Timestamp ...\n"))).check()
        XCTAssertEqual(result.health, .normal)
        XCTAssertEqual(result.eventCount, 0)
        XCTAssertTrue(result.summary.contains("No watchdog events observed"))
        XCTAssertNotNil(result.coverageThrough)
    }

    func testWatchdogRetainsFirstLastEventsAndPIDs() {
        let result = TCCWatchdogDiagnostic(runner: FakeRunner(result: CommandResult(stdout: example))).check()
        XCTAssertEqual(result.health, .warning)
        XCTAssertEqual(result.eventCount, 2)
        XCTAssertEqual(result.countsByService["SystemPolicyDownloadsFolder"], 1)
        XCTAssertEqual(result.countsByPID?["85402"], 1)
        XCTAssertEqual(result.countsByPID?["85401"], 1)
        XCTAssertEqual(result.firstEvent?.timestamp, "2026-10-12 18:24:55.024")
        XCTAssertEqual(result.lastEvent?.timestamp, "2026-10-12 18:25:00.024")
    }

    func testFailedQueriesNeverProduceFalseNormalOrAdvanceCoverage() {
        for result in [
            CommandResult(stdout: "", exitCode: 1),
            CommandResult(stdout: "", timedOut: true),
            CommandResult(stdout: "", exitCode: nil, error: "missing binary")
        ] {
            let status = TCCWatchdogDiagnostic(runner: FakeRunner(result: result)).check()
            XCTAssertEqual(status.health, .unknown)
            XCTAssertNil(status.eventCount)
            XCTAssertNil(status.coverageThrough)
            if !result.timedOut {
                XCTAssertNil(status.requiresBaselineReset)
            }
        }
    }

    func testNonSizeFailuresDoNotBisectOrOfferReset() {
        for failure in [
            CommandResult(stdout: "", exitCode: 1),
            CommandResult(stdout: "", exitCode: nil, error: "missing binary")
        ] {
            let runner = SequencedRunner([failure])
            let result = TCCWatchdogDiagnostic(runner: runner).check()
            XCTAssertEqual(runner.calls.count, 1, "Non-size failures must not trigger retries")
            XCTAssertEqual(result.health, .unknown)
            XCTAssertNil(result.requiresBaselineReset)
            XCTAssertNil(result.coverageThrough)
            XCTAssertNil(result.eventCount)
        }
    }

    func testSizeFailureAtMinimumChunkRequiresReset() {
        let runner = SequencedRunner([CommandResult(stdout: "", truncated: true)])
        let result = TCCWatchdogDiagnostic(
            runner: runner, chunkDuration: 30, minimumChunkDuration: 30
        ).check()
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(result.health, .unknown)
        XCTAssertEqual(result.requiresBaselineReset, true)
        XCTAssertNil(result.coverageThrough)
    }

    func testTruncatedCapturedWatchdogIsWarningWithoutCoverage() {
        let result = TCCWatchdogDiagnostic(runner: FakeRunner(
            result: CommandResult(stdout: example, truncated: true)),
            maximumChunkAttempts: 1).check()
        XCTAssertEqual(result.health, .warning)
        XCTAssertEqual(result.eventCount, 2)
        XCTAssertNil(result.coverageThrough)
        XCTAssertTrue(result.summary.contains("partial coverage"))
    }

    func testParserIsCaseInsensitiveAndNeverDropsUnclassifiedWatchdogs() {
        let line = "2026-10-12 18:25:00.024 Df kernel[0:a] (Sandbox) Watchdog Expired For Approval of OTHER_TOKEN pid 23"
        let events = TCCWatchdogParser.parse(line)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].service, "Unclassified")
        XCTAssertEqual(events[0].processID, 23)
    }

    func testBackfillsAcrossFailedChecksAndSleep() {
        let origin = Date(timeIntervalSince1970: 1_797_000_000)
        let recorder = RecordedCall()
        let diagnostic = TCCWatchdogDiagnostic(runner: FakeRunner(
            result: CommandResult(stdout: example), recorder: recorder))
        let recovered = diagnostic.check(since: origin, at: origin.addingTimeInterval(4 * 60))
        XCTAssertEqual(recovered.health, .warning)
        XCTAssertEqual(recovered.coverageThrough, origin.addingTimeInterval(240))
        let from = recorder.arguments.firstIndex(of: "--start")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(recorder.arguments[from + 1], formatter.string(from: origin.addingTimeInterval(-2)))
        XCTAssertFalse(recorder.arguments.contains("--last"))
    }

    func testUnrecoverableGapMustNotBeGreen() {
        let origin = Date(timeIntervalSince1970: 1_797_000_000)
        let diagnostic = TCCWatchdogDiagnostic(
            runner: FakeRunner(result: CommandResult(stdout: "")),
            maximumCatchupInterval: 3600)
        let result = diagnostic.check(since: origin, at: origin.addingTimeInterval(7200))
        XCTAssertEqual(result.health, .unknown)
        XCTAssertEqual(result.requiresBaselineReset, true)
        XCTAssertNil(result.coverageThrough)
    }

    func testResetBaselineOnlyCoversRecentWindow() {
        let origin = Date(timeIntervalSince1970: 1_797_000_000)
        let recorder = RecordedCall()
        let diagnostic = TCCWatchdogDiagnostic(runner: FakeRunner(
            result: CommandResult(stdout: ""), recorder: recorder))
        let result = diagnostic.check(since: nil, at: origin)
        XCTAssertEqual(result.health, .normal)
        XCTAssertEqual(result.coverageThrough, origin)
        XCTAssertTrue(recorder.arguments.contains("--start"))
    }

    func testAggregateHealthPriority() {
        let normal = DiagnosticResult(id: "n", title: "n", health: .normal, summary: "", eventCount: 0, countsByService: [:], elapsedSeconds: 0)
        let unknown = DiagnosticResult(id: "u", title: "u", health: .unknown, summary: "", eventCount: nil, countsByService: [:], elapsedSeconds: 0)
        let warning = DiagnosticResult(id: "w", title: "w", health: .warning, summary: "", eventCount: 1, countsByService: [:], elapsedSeconds: 0)
        XCTAssertEqual(MonitorSnapshot(timestamp: .now, diagnostics: [normal]).health, .normal)
        XCTAssertEqual(MonitorSnapshot(timestamp: .now, diagnostics: [normal, unknown]).health, .unknown)
        XCTAssertEqual(MonitorSnapshot(timestamp: .now, diagnostics: [unknown, warning]).health, .warning)
        XCTAssertEqual(MonitorSnapshot(timestamp: .now, diagnostics: []).health, .unknown)
    }

    func testHistoricalResultsRemainDecodable() throws {
        let old = """
        [{"timestamp":1000,"diagnostics":[{"id":"tcc-watchdog","title":"TCC / Sandbox","health":"normal","summary":"OK","eventCount":0,"countsByService":{},"elapsedSeconds":0.3}]}]
        """
        let snapshots = try JSONDecoder().decode([MonitorSnapshot].self, from: Data(old.utf8))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNil(snapshots[0].diagnostics[0].countsByPID)
        XCTAssertNil(snapshots[0].diagnostics[0].coverageThrough)
    }

    func testHistoryRoundTripAndLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), limit: 2)
        XCTAssertTrue(store.load().isEmpty)
        let items = (0..<3).map { MonitorSnapshot(timestamp: Date(timeIntervalSince1970: Double($0)), diagnostics: []) }
        store.save(items)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].timestamp, items[0].timestamp)
    }

    func testBackfillAdvancesCheckpointThroughSuccessfulChunksBeforeFailure() {
        let start = Date(timeIntervalSince1970: 1_797_000_000)
        let runner = SequencedRunner([
            CommandResult(stdout: example),
            CommandResult(stdout: "", timedOut: true),
            CommandResult(stdout: "", timedOut: true)
        ])
        let diagnostic = TCCWatchdogDiagnostic(runner: runner, chunkDuration: 60,
            minimumChunkDuration: 30, maximumChunkAttempts: 3)
        let result = diagnostic.check(since: start, at: start.addingTimeInterval(600))
        XCTAssertEqual(result.health, .warning)
        XCTAssertEqual(result.eventCount, 2)
        XCTAssertEqual(result.coverageThrough, start.addingTimeInterval(58))
        XCTAssertTrue(result.summary.contains("partial coverage"))
        XCTAssertTrue(runner.calls.allSatisfy { $0.contains("--end") })
        XCTAssertEqual(runner.calls.count, 3)
    }

    func testBackfillReplaysOverlapWithoutDoubleCountingSameEntry() {
        let start = Date(timeIntervalSince1970: 1_797_000_000)
        let runner = SequencedRunner(Array(repeating: CommandResult(stdout: example), count: 4))
        let result = TCCWatchdogDiagnostic(runner: runner, chunkDuration: 60)
            .check(since: start, at: start.addingTimeInterval(180))
        XCTAssertEqual(result.health, .warning)
        XCTAssertEqual(result.eventCount, 2)
        XCTAssertEqual(result.coverageThrough, start.addingTimeInterval(180))
    }

    func testMalformedHistoryIsPreservedBeforeSaving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.json")
        try Data("CORRUPT_JSON".utf8).write(to: file)
        let store = HistoryStore(fileURL: file)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("history.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(backups[0])), "CORRUPT_JSON")
        store.save([MonitorSnapshot(timestamp: .now, diagnostics: [])])
        XCTAssertEqual(store.load().count, 1)
    }

    #if os(macOS)
    func testRealMacOSUnifiedLoggingPredicateSmoke() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = Date()
        let result = BoundedCommandRunner(maximumOutputBytes: 262_144).run(
            executable: "/usr/bin/log",
            arguments: ["show", "--start", formatter.string(from: now.addingTimeInterval(-30)),
                        "--end", formatter.string(from: now),
                        "--style", "compact", "--no-pager",
                        "--predicate", "process == \"kernel\" AND eventMessage CONTAINS[c] \"watchdog expired for approval\""],
            timeout: 20)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testMenuBarStatusSymbolsAreValid() {
        for symbol in ["checkmark.shield.fill", "exclamationmark.shield.fill",
                       "questionmark.circle.fill", "arrow.triangle.2.circlepath"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }
    #endif

    func testRealCommandRunnerExitCodeAndCapture() {
        let result = BoundedCommandRunner(maximumOutputBytes: 1024).run(
            executable: "/bin/sh", arguments: ["-c", "printf 'hello'; printf 'oops' >&2; exit 7"], timeout: 3)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertEqual(result.stderr, "oops")
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.truncated)
        XCTAssertNil(result.error)
    }

    func testRealCommandRunnerTimeout() {
        let start = Date()
        let result = BoundedCommandRunner().run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.15)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRealCommandRunnerStopsUnboundedOutput() {
        let start = Date()
        let result = BoundedCommandRunner(maximumOutputBytes: 2048).run(
            executable: "/bin/sh", arguments: ["-c", "while :; do printf '0123456789abcdef'; done"], timeout: 5)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.stdout.utf8.count + result.stderr.utf8.count, 4096)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}
