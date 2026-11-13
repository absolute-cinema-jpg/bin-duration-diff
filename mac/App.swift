// Bin Duration Diff -- native Mac front end for bin_diff.py.
// App entry point, menus, shared state and small helpers.

import SwiftUI
import AppKit

enum AppInfo {
    static let repo = "absolute-cinema-jpg/bin-duration-diff"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

#if !SNAPSHOT
@main
#endif
struct BinDurationDiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, idealWidth: 700, minHeight: 400)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}                     // one window is enough
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsView.open() }.keyboardShortcut(",")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
            }
            CommandGroup(replacing: .help) {
                Button("Report a Bug…") { BugReportView.open() }
                Button("Bin Duration Diff on GitHub") { NSWorkspace.shared.open(AppInfo.repoURL) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Updater.shared.checkAutomaticallyIfDue()
        }
    }
}

/// Things several windows need to know about.
final class AppState: ObservableObject {
    static let shared = AppState()
    /// The most recent error shown in the main window (offered to the bug report).
    @Published var lastError: String?
}

/// Opens (or brings forward) a simple AppKit window hosting a SwiftUI view.
enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func show<V: View>(_ id: String, title: String, size: NSSize, resizable: Bool = false, _ view: () -> V) {
        if let w = open[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view()))
        w.title = title
        w.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            open[id] = nil
        }
        open[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close(_ id: String) { open[id]?.close() }
}

func showAlert(_ title: String, _ text: String = "", style: NSAlert.Style = .informational) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.alertStyle = style
    a.runModal()
}
