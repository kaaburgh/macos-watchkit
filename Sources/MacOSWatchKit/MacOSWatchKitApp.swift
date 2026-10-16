import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MonitorStore.shared.start()
    }
}

@main
struct MacOSWatchKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = MonitorStore.shared

    var body: some Scene {
        MenuBarExtra("macOS WatchKit", systemImage: monitor.symbol) {
            MonitorMenuView(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
