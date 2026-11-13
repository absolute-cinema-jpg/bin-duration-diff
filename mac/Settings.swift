// Settings: where reports go, which columns are compared, and what the report contains.
//
// Everything lives in UserDefaults under the app's bundle ID, which never changes
// (it's still "local.bin-duration-diff" from 1.x), so settings survive quitting,
// updating and the rename to Bin Diff. Engine.swift turns them into engine arguments.

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
    static let ignoredColumns = "ignoredColumns"        // [String]
    static let knownColumns = "knownColumns"            // [String]
    static let ignoreValueCase = "ignoreValueCase"
    static let autoSave = "autoSaveReports"                // 2.1: reports open in the app; saving is optional
    static let alsoOpenInBrowser = "alsoOpenInBrowser"
    static let reportUnchecked = "reportUncheckedColumns"  // [String], columns unticked in the report

    /// Where reports live while they're open in the app (when auto-save is off).
    static var workFolderURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Bin Diff/Reports", isDirectory: true)
    }

    /// Delete work-folder reports older than a few days.
    static func tidyWorkFolder() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        let items = (try? fm.contentsOfDirectory(at: workFolderURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if d < cutoff { try? fm.removeItem(at: u) }
        }
    }

    /// ~/Documents/Bin Diff Reports -- or the 1.x folder if reports already go there.
    static var defaultReportsFolder: URL {
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        let old = docs.appendingPathComponent("Bin Duration Reports", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) { return old }
        return docs.appendingPathComponent("Bin Diff Reports", isDirectory: true)
    }

    static var reportsFolderURL: URL {
        let p = UserDefaults.standard.string(forKey: reportsFolder) ?? ""
        return p.isEmpty ? defaultReportsFolder : URL(fileURLWithPath: p, isDirectory: true)
    }

    static func bool(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }
}

/// Which metadata columns are compared. Clips are always linked by Tape.
final class ColumnPrefs: ObservableObject {
    static let shared = ColumnPrefs()

    /// Columns Bin Diff reads from .avb bins (named like Avid's bin columns).
    static let builtIn = ["Name", "Duration", "Start", "End", "Tracks", "FPS", "Resolution",
                          "Creation Date", "Modified Date"]
    static let ignoredByDefault = ["Modified Date"]

    @Published private(set) var known: [String]
    @Published private(set) var ignored: [String]

    private init() {
        let d = UserDefaults.standard
        known = d.stringArray(forKey: Prefs.knownColumns) ?? ColumnPrefs.builtIn
        ignored = d.stringArray(forKey: Prefs.ignoredColumns) ?? ColumnPrefs.ignoredByDefault
    }

    func isCompared(_ c: String) -> Bool { !ignored.contains { $0.caseInsensitiveCompare(c) == .orderedSame } }

    func setCompared(_ c: String, _ on: Bool) {
        ignored.removeAll { $0.caseInsensitiveCompare(c) == .orderedSame }
        if !on { ignored.append(c) }
        save()
    }

    /// Remember columns seen in compared bins so they can be switched off here.
    func remember(_ cols: [String]) {
        var changed = false
        for c in cols where !c.isEmpty && !known.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) {
            known.append(c); changed = true
        }
        if changed { save() }
    }

    func add(_ c: String) {
        let t = c.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.lowercased() != "tape" else { return }
        remember([t])
    }

    func forgetUnused() {
        known = ColumnPrefs.builtIn + known.filter { c in
            !ColumnPrefs.builtIn.contains(c) && !isCompared(c)    // keep the ones switched off
        }
        save()
    }

    func resetToDefaults() {
        ignored = ColumnPrefs.ignoredByDefault
        save()
    }

    private func save() {
        UserDefaults.standard.set(known, forKey: Prefs.knownColumns)
        UserDefaults.standard.set(ignored, forKey: Prefs.ignoredColumns)
    }
}

/// Report parts. Keys match bin_diff.py's --hide / --show options.
enum ReportParts {
    static let sections: [(String, String)] = [
        ("paths", "Full bin file paths"),
        ("summary", "Summary boxes at the top"),
        ("by_column", "Differences by column (with show/hide ticks)"),
        ("durations", "Duration differences, ranked"),
        ("metadata", "Metadata differences"),
        ("columns", "Columns that weren't compared"),
        ("only_a", "Clips only in bin A"),
        ("only_b", "Clips only in bin B"),
        ("no_tape", "Clips with no tape name"),
        ("same", "Clips identical in every column"),
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
        Windows.show("settings", title: "Bin Diff Settings", size: NSSize(width: 600, height: 540)) {
            SettingsView()
        }
    }

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Text("General") }
            ColumnSettings().tabItem { Text("Columns") }
            ReportSettings().tabItem { Text("Report") }
            UpdateSettings().tabItem { Text("Updates") }
        }
        .padding(16)
        .frame(width: 600, height: 540)
    }
}

struct GeneralSettings: View {
    @AppStorage(Prefs.reportsFolder) private var folder = ""
    @AppStorage(Prefs.autoSave) private var autoSave = false
    @AppStorage(Prefs.alsoOpenInBrowser) private var alsoOpenInBrowser = false
    @AppStorage(Prefs.writeCSV) private var writeCSV = true
    @AppStorage(Prefs.tolerance) private var tolerance = 0
    @AppStorage(Prefs.caseSensitive) private var caseSensitive = false
    @AppStorage(Prefs.includeSubclips) private var includeSubclips = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("Reports").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reports open in Bin Diff. Use Export PDF… in the report to save one.")
                        .foregroundColor(.secondary)
                    Text("Save and export reports in:")
                    HStack {
                        Image(systemName: "folder")
                        Text(displayPath).lineLimit(1).truncationMode(.middle)
                            .help(Prefs.reportsFolderURL.path)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                        Button("Default") { folder = "" }.disabled(folder.isEmpty)
                    }
                    Toggle("Also save every report automatically (HTML)", isOn: $autoSave)
                    Toggle("Include a CSV spreadsheet with each saved report", isOn: $writeCSV)
                        .disabled(!autoSave).padding(.leading, 20)
                    Toggle("Also open each report in my web browser", isOn: $alsoOpenInBrowser)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Matching").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: $tolerance, in: 0...500) {
                        Text(tolerance == 0 ? "Flag every duration difference, even 1 frame"
                                            : "Ignore duration differences of \(tolerance) frame\(tolerance == 1 ? "" : "s") or less")
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

struct ColumnSettings: View {
    @ObservedObject private var cols = ColumnPrefs.shared
    @AppStorage(Prefs.ignoreValueCase) private var ignoreValueCase = false
    @State private var newColumn = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text("Clips are always linked by ") + Text("Tape").bold()
                + Text(". Every other column the two bins share is compared — untick any you don't care about."))
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(label: Text("Compare these columns").bold()) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                        GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(cols.known, id: \.self) { c in
                            Toggle(c, isOn: Binding(get: { cols.isCompared(c) },
                                                    set: { cols.setCompared(c, $0) }))
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: .infinity)
            }

            Text("Columns from bins you compare are added to this list automatically. Columns that appear in only one of the two bins can't be compared and are listed in the report.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Add a column by name, e.g. Camroll", text: $newColumn, onCommit: addColumn)
                    .frame(maxWidth: 260)
                Button("Add", action: addColumn).disabled(newColumn.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Menu("More") {
                    Button("Compare all except Modified Date") { cols.resetToDefaults() }
                    Button("Tidy list (remove columns not switched off)") { cols.forgetUnused() }
                }
                .frame(width: 80)
            }
            Toggle("Ignore upper/lower case differences in values (e.g. “Day 1” = “DAY 1”)", isOn: $ignoreValueCase)
        }
    }

    private func addColumn() {
        cols.add(newColumn)
        newColumn = ""
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
                VStack(spacing: 12) {
                    GroupBox(label: Text("Duration table columns").bold()) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Rank and Clip are always shown.").font(.caption).foregroundColor(.secondary)
                            ForEach(ReportParts.columns, id: \.0) { ReportToggle($0.0, $0.1) }
                        }
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox(label: Text("Extra duration table columns").bold()) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(ReportParts.extras, id: \.0) { ReportToggle($0.0, $0.1) }
                        }
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Which columns are compared is set on the Columns tab; which ones you see is ticked in the report itself. Changes apply to the next comparison.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Text("Your settings are kept when you quit or update.")
                        .font(.caption).foregroundColor(.secondary)
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
            Text("Bin Diff is free software under the GNU General Public License v3.")
                .font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }
}
