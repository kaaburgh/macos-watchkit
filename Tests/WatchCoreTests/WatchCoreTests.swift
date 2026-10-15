import Foundation
import XCTest
@testable import WatchCore

private struct FakeRunner: CommandRunning {
    let result: CommandResult
    func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult { result }
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
}
