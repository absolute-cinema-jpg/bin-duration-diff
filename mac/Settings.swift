// Settings: where reports go, how clips are matched, and what the report contains.
// Everything lives in UserDefaults; Engine.swift turns it into engine arguments.

import SwiftUI
import AppKit

enum Prefs {
    static let reportsFolder = "reportsFolder"          // "" = default
    static let openReport = "openReportAutomatically"
    static let writeCSV = "writeCSV"
    static let tolerance = "toleranceFrames"
    static let caseSensitive = "caseSensitiveTapes"
    static let includeSubclips = "includeSubclips"
    static let autoUpdate = "checkForUpdatesAutomatically"

    static var defaultReportsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Bin Duration Reports", isDirectory: true)
    }

    static var reportsFolderURL: URL {
        let p = UserDefaults.standard.string(forKey: reportsFolder) ?? ""
        return p.isEmpty ? defaultReportsFolder : URL(fileURLWithPath: p, isDirectory: true)
    }

    static func bool(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
}

/// Report parts. Keys match bin_diff.py's --hide / --show options.
enum ReportParts {
    static let sections: [(String, String)] = [
        ("paths", "Full bin file paths"),
        ("summary", "Summary boxes at the top"),
        ("only_a", "Clips only in bin A"),
        ("only_b", "Clips only in bin B"),
        ("no_tape", "Clips with no tape name"),
        ("same", "Clips with the same duration"),
    ]
    static let columns: [(String, String)] = [
        ("tape", "Tape"),
        ("dur_a", "Duration A"),
        ("dur_b", "Duration B"),
        ("diff_tc", "Difference (timecode)"),
        ("diff_frames", "Difference (frames)"),
        ("diff_sec", "Difference (seconds)"),
        ("direction", "B longer / shorter"),
        ("magnitude", "Magnitude bar"),
    ]
    static let extras: [(String, String)] = [
        ("start_tc", "Start timecode (A and B)"),
        ("frames", "Frame counts (A and B)"),
        ("fps", "Frame rate"),
    ]
    static let defaultOn = (sections + columns).map { $0.0 }

    static func key(_ part: String) -> String { "report.\(part)" }
    static func isOn(_ part: String) -> Bool {
        Prefs.bool(key(part), !extras.contains { $0.0 == part })
    }
    static func resetAll() {
        for (k, _) in sections + columns + extras { UserDefaults.standard.removeObject(forKey: key(k)) }
    }
}

struct SettingsView: View {
    static func open() {
        Windows.show("settings", title: "Bin Duration Diff Settings", size: NSSize(width: 560, height: 470)) {
            SettingsView()
        }
    }

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Text("General") }
            ReportSettings().tabItem { Text("Report") }
            UpdateSettings().tabItem { Text("Updates") }
        }
        .padding(16)
        .frame(width: 560, height: 470)
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.reportsFolder) private var folder = ""
    @AppStorage(Prefs.openReport) private var openReport = true
    @AppStorage(Prefs.writeCSV) private var writeCSV = true
    @AppStorage(Prefs.tolerance) private var tolerance = 0
    @AppStorage(Prefs.caseSensitive) private var caseSensitive = false
    @AppStorage(Prefs.includeSubclips) private var includeSubclips = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("Reports").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save reports in:")
                    HStack {
                        Image(systemName: "folder")
                        Text(displayPath).lineLimit(1).truncationMode(.middle)
                            .help(Prefs.reportsFolderURL.path)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                        Button("Default") { folder = "" }.disabled(folder.isEmpty)
                    }
                    Toggle("Open the report in my browser after comparing", isOn: $openReport)
                    Toggle("Also save a CSV spreadsheet next to each report", isOn: $writeCSV)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Matching").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: $tolerance, in: 0...500) {
                        Text(tolerance == 0 ? "Flag every difference, even 1 frame"
                                            : "Ignore differences of \(tolerance) frame\(tolerance == 1 ? "" : "s") or less")
                    }
                    Toggle("Tape names must match upper/lower case exactly", isOn: $caseSensitive)
                    Toggle("Include subclips when a bin also has master clips", isOn: $includeSubclips)
                    Text("A bin with only subclips (e.g. AutoSync bins) always uses its subclips.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }

    private var displayPath: String {
        let p = Prefs.reportsFolderURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save reports"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.reportsFolderURL
        if panel.runModal() == .OK, let u = panel.url { folder = u.path }
    }
}

struct ReportToggle: View {
    let part: String
    let label: String
    @AppStorage private var on: Bool

    init(_ part: String, _ label: String) {
        self.part = part
        self.label = label
        _on = AppStorage(wrappedValue: !ReportParts.extras.contains { $0.0 == part }, ReportParts.key(part))
    }

    var body: some View { Toggle(label, isOn: $on) }
}

struct ReportSettings: View {
    @State private var resetToken = UUID()   // re-creates toggles after "Restore Defaults"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                GroupBox(label: Text("Sections").bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ReportParts.sections, id: \.0) { ReportToggle($0.0, $0.1) }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(label: Text("Differences table columns").bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rank and Clip are always shown.").font(.caption).foregroundColor(.secondary)
                        ForEach(ReportParts.columns, id: \.0) { ReportToggle($0.0, $0.1) }
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GroupBox(label: Text("Extra information").bold()) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ReportParts.extras, id: \.0) { ReportToggle($0.0, $0.1) }
                    Text("Added to every table in the report and to the CSV.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Changes apply to the next comparison.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Restore Defaults") { ReportParts.resetAll(); resetToken = UUID() }
            }
        }
        .id(resetToken)
    }
}

struct UpdateSettings: View {
    @AppStorage(Prefs.autoUpdate) private var autoUpdate = true
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("Updates").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("You have version \(AppInfo.version).")
                        Spacer()
                        Text("by Alex Stuart").font(.caption).foregroundColor(.secondary)
                    }
                    Toggle("Check for updates automatically (once a day)", isOn: $autoUpdate)
                    HStack {
                        Button("Check Now") { updater.check(userInitiated: true) }.disabled(updater.busy)
                        if updater.busy { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) }
                        Text(updater.status).foregroundColor(.secondary).lineLimit(2)
                    }
                    Link("All releases on GitHub", destination: AppInfo.repoURL.appendingPathComponent("releases"))
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(label: Text("Problems?").bold()) {
                HStack {
                    Text("Something not working right? Let us know.")
                    Spacer()
                    Button("Report a Bug…") { BugReportView.open() }
                }
                .padding(6)
            }
            Spacer(minLength: 0)
        }
    }
}
