import AppKit
import SwiftUI
import WatchCore

private extension DiagnosticHealth {
    var tint: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .unknown: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct MonitorMenuView: View {
    @ObservedObject var monitor: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: monitor.health.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(monitor.health.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("System status").font(.headline)
                    Text(monitor.statusText).font(.subheadline)
                }
                Spacer()
                if monitor.isChecking { ProgressView().controlSize(.small) }
            }

            Divider()

            if let snapshot = monitor.latest {
                ForEach(snapshot.diagnostics) { result in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(result.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: result.health.symbol)
                                .foregroundStyle(result.health.tint)
                        }
                        Text(result.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(result.countsByService.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                            HStack {
                                Text(entry.key).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(entry.value)").monospacedDigit()
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        if let pids = result.countsByPID, !pids.isEmpty {
                            Text("Affected PIDs").font(.caption.weight(.semibold))
                            ForEach(pids.sorted(by: { $0.value > $1.value }), id: \.key) { entry in
                                HStack {
                                    Text(entry.key)
                                    Spacer()
                                    Text("\(entry.value)").monospacedDigit()
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let first = result.firstEvent {
                            Text("First: \(first.timestamp ?? "Unknown time") — PID \(first.processID.map(String.init) ?? "?")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let last = result.lastEvent {
                            Text("Last: \(last.timestamp ?? "Unknown time") — PID \(last.processID.map(String.init) ?? "?")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if result.requiresBaselineReset == true {
                            Text("A monitoring gap cannot be backfilled. Starting a new baseline explicitly accepts this unverified interval.")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Start new baseline") { monitor.checkNow(resetBaseline: true) }
                                .disabled(monitor.isChecking)
                        }
                    }
                }
                Text("Checked \(snapshot.timestamp.formatted(date: .abbreviated, time: .standard)) · every 2 min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("The first log check will run shortly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Check now") { monitor.checkNow() }
                    .disabled(monitor.isChecking)
                Button("Copy report") { monitor.copyReport() }
                    .disabled(monitor.history.isEmpty)
            }

            if !monitor.history.isEmpty {
                Divider()
                DisclosureGroup("Recent checks") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(monitor.history.prefix(8))) { snapshot in
                            HStack(spacing: 8) {
                                Image(systemName: snapshot.health.symbol)
                                    .foregroundStyle(snapshot.health.tint)
                                Text(snapshot.timestamp.formatted(date: .omitted, time: .standard))
                                Spacer()
                                Text(snapshot.diagnostics.first?.eventCount.map { "\($0) watchdogs" } ?? "Unknown")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }

            Divider()

            HStack {
                Text("Passive checks only — no protected-folder access")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
