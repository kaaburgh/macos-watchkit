import Foundation
import XCTest
@testable import WatchCore

private struct FakeRunner: CommandRunning {
    let result: CommandResult
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult { result }
}

private final class RecordingRunner: CommandRunning {
    let result: CommandResult
    private(set) var arguments: [String] = []
    init(result: CommandResult) { self.result = result }
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        self.arguments = arguments
        return result
    }
}

final class WatchCoreTests: XCTestCase {
    private let example = """
    Timestamp               Ty Process[PID:TID]
    2026-10-12 18:24:55.024 Df kernel[0:3d8b] (Sandbox) watchdog expired for approval entry 3174168 (kTCCServiceSystemPolicyDownloadsFolder, pid 85402)
    2026-10-12 18:25:00.024 Df kernel[0:3d8b] (Sandbox) watchdog expired for approval entry 3174169 (kTCCServiceSystemPolicyDocumentsFolder, pid 85401)
    2026-10-12 18:25:01.024 Df kernel[0:3d8b] informational message unrelated to watchdog
    """

    func testParseEventsAndServices() {
        let events = TCCWatchdogParser.parse(example)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.service), ["SystemPolicyDownloadsFolder", "SystemPolicyDocumentsFolder"])
        XCTAssertEqual(events.map(\.processID), [85402, 85401])
    }

    func testNoEventsIsNormalButQualified() {
        let result = TCCWatchdogDiagnostic(runner: FakeRunner(result: CommandResult(stdout: "Timestamp ...\n"))).check()
        XCTAssertEqual(result.health, .normal)
        XCTAssertEqual(result.eventCount, 0)
        XCTAssertTrue(result.summary.contains("No watchdog events observed"))
    }

    func testWatchdogIsWarning() {
        let result = TCCWatchdogDiagnostic(runner: FakeRunner(result: CommandResult(stdout: example))).check()
        XCTAssertEqual(result.health, .warning)
        XCTAssertEqual(result.eventCount, 2)
        XCTAssertEqual(result.countsByService["SystemPolicyDownloadsFolder"], 1)
    }

    func testFailedQueriesNeverProduceFalseNormal() {
        for result in [
            CommandResult(stdout: "", exitCode: 1),
            CommandResult(stdout: "", timedOut: true),
            CommandResult(stdout: example, truncated: true),
            CommandResult(stdout: "", exitCode: nil, error: "missing binary")
        ] {
            let status = TCCWatchdogDiagnostic(runner: FakeRunner(result: result)).check()
            XCTAssertEqual(status.health, .unknown)
            XCTAssertNil(status.eventCount)
        }
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

    func testParseEventTimestamps() {
        let events = TCCWatchdogParser.parse(example)
        XCTAssertEqual(events.map(\.timestamp), [
            "2026-10-12 18:24:55.024", "2026-10-12 18:25:00.024"
        ])
    }

    func testPreservesFirstLastAndPIDCounts() {
        let result = TCCWatchdogDiagnostic(runner: FakeRunner(result: CommandResult(stdout: example))).check()
        XCTAssertEqual(result.countsByPID?["85402"], 1)
        XCTAssertEqual(result.countsByPID?["85401"], 1)
        XCTAssertEqual(result.firstEvent?.timestamp, "2026-10-12 18:24:55.024")
        XCTAssertEqual(result.lastEvent?.timestamp, "2026-10-12 18:25:00.024")
    }

    func testBackfillsAcrossFailedChecks() {
        let origin = Date(timeIntervalSince1970: 1_797_000_000)
        let runner = RecordingRunner(result: CommandResult(stdout: example))
        let result = TCCWatchdogDiagnostic(runner: runner)
            .check(since: origin, at: origin.addingTimeInterval(240))
        XCTAssertEqual(result.health, .warning)
        XCTAssertEqual(result.coverageThrough, origin.addingTimeInterval(240))
        let idx = runner.arguments.firstIndex(of: "--start")!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(runner.arguments[idx + 1], fmt.string(from: origin.addingTimeInterval(-2)))
    }

    func testFailedQueryNeverAdvancesCoverage() {
        let origin = Date(timeIntervalSince1970: 1_797_000_000)
        let result = TCCWatchdogDiagnostic(
            runner: FakeRunner(result: CommandResult(stdout: "", timedOut: true))
        ).check(since: origin, at: origin.addingTimeInterval(240))
        XCTAssertEqual(result.health, .unknown)
        XCTAssertNil(result.coverageThrough)
    }

    func testUnrecoverableGapIsUnknownUntilExplicitReset() {
        let origin = Date(timeIntervalSince1970: 1_797_000_000)
        let diagnostic = TCCWatchdogDiagnostic(
            runner: FakeRunner(result: CommandResult(stdout: "")),
            maximumCatchupInterval: 3600
        )
        let result = diagnostic.check(since: origin, at: origin.addingTimeInterval(7200))
        XCTAssertEqual(result.health, .unknown)
        XCTAssertEqual(result.requiresBaselineReset, true)
        XCTAssertNil(result.coverageThrough)
    }

    func testLegacyHistoryRemainsDecodable() throws {
        let json = """
        [{"timestamp":1000,"diagnostics":[{"id":"tcc-watchdog","title":"TCC / Sandbox","health":"normal","summary":"OK","eventCount":0,"countsByService":{},"elapsedSeconds":0.3}]}]
        """
        let items = try JSONDecoder().decode([MonitorSnapshot].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].diagnostics[0].coverageThrough)
        XCTAssertNil(items[0].diagnostics[0].countsByPID)
    }

    func testRealCommandRunnerExitTimeoutAndOutputCap() {
        let runner = BoundedCommandRunner(maximumOutputBytes: 2048)
        let exit = runner.run(executable: "/bin/sh",
                              arguments: ["-c", "printf hello; printf oops >&2; exit 7"], timeout: 3)
        XCTAssertEqual(exit.stdout, "hello")
        XCTAssertEqual(exit.stderr, "oops")
        XCTAssertEqual(exit.exitCode, 7)
        XCTAssertFalse(exit.truncated)

        let timeout = runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.15)
        XCTAssertTrue(timeout.timedOut)

        let flood = runner.run(executable: "/bin/sh",
                               arguments: ["-c", "while :; do printf '0123456789abcdef'; done"],
                               timeout: 5)
        XCTAssertTrue(flood.truncated)
        XCTAssertLessThanOrEqual(flood.stdout.utf8.count + flood.stderr.utf8.count, 2048)
    }
}
