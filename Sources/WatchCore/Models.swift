import Foundation

public enum DiagnosticHealth: String, Codable, Sendable {
    case normal
    case warning
    case unknown
}

public struct DiagnosticResult: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let health: DiagnosticHealth
    public let summary: String
    public let eventCount: Int?
    public let countsByService: [String: Int]
    public let elapsedSeconds: Double

    public init(
        id: String, title: String, health: DiagnosticHealth,
        summary: String, eventCount: Int?, countsByService: [String: Int],
        elapsedSeconds: Double
    ) {
        self.id = id
        self.title = title
        self.health = health
        self.summary = summary
        self.eventCount = eventCount
        self.countsByService = countsByService
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct MonitorSnapshot: Codable, Sendable, Identifiable {
    public let timestamp: Date
    public let diagnostics: [DiagnosticResult]

    public var id: Date { timestamp }

    public init(timestamp: Date, diagnostics: [DiagnosticResult]) {
        self.timestamp = timestamp
        self.diagnostics = diagnostics
    }

    public var health: DiagnosticHealth {
        if diagnostics.contains(where: { $0.health == .warning }) { return .warning }
        if diagnostics.isEmpty || diagnostics.contains(where: { $0.health == .unknown }) { return .unknown }
        return .normal
    }
}

public protocol SystemDiagnostic {
    var id: String { get }
    var title: String { get }
    func check() -> DiagnosticResult
}
