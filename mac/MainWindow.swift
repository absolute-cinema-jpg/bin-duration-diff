// Main window: Bin A and Bin B side by side, Compare, result summary.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

let binExtensions = ["avb", "ale", "txt", "tab", "tsv", "csv"]
let frameRates = ["23.976", "24", "25", "29.97", "30", "48", "50", "59.94", "60"]

struct ContentView: View {
    @State private var binA: URL?
    @State private var binB: URL?
    @AppStorage("textFPS") private var fps = "24"
    @AppStorage(Prefs.alsoOpenInBrowser) private var alsoOpenInBrowser = false
    @State private var savedCopy = false
    @State private var running = false
    @State private var summary: Summary?
    @State private var errorText: String?

    init(binA: URL? = nil, binB: URL? = nil, summary: Summary? = nil, error: String? = nil) {
        _binA = State(initialValue: binA)
        _binB = State(initialValue: binB)
        _summary = State(initialValue: summary)
        _errorText = State(initialValue: error)
    }

    private var needsFPS: Bool {
        [binA, binB].compactMap { $0 }.contains { !["avb", "ale"].contains($0.pathExtension.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare two bins")
                    .font(.title2).bold()
                Text("Clips are linked by tape name, and every other column is compared. Choose a bin for each side, or drag bins in from Finder.")
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                BinSlot(label: "Bin A", url: $binA, onDropMany: fillBoth)
                Button(action: { let t = binA; binA = binB; binB = t; summary = nil }) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Swap A and B")
                .disabled(binA == nil && binB == nil)
                BinSlot(label: "Bin B", url: $binB, onDropMany: fillBoth)
            }
            .frame(minHeight: 150)

            if needsFPS {
                Picker("Frame rate of the exported text bin:", selection: $fps) {
                    ForEach(frameRates, id: \.self) { Text($0 + " fps").tag($0) }
                }
                .frame(maxWidth: 360)
            }

            if let s = summary { ResultBox(summary: s, savedCopy: savedCopy) }
            if let e = errorText {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(e).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Report This Problem…") { BugReportView.open() }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button(action: { SettingsView.open() }) { Image(systemName: "gearshape") }
                    .help("Settings")
                Button("Report a Bug…") { BugReportView.open() }
                if running {
                    ProgressView().scaleEffect(0.6).frame(width: 20, height: 20)
                    Text("Comparing…").foregroundColor(.secondary)
                }
                Spacer()
                Button("Compare", action: compare)
                    .keyboardShortcut(.defaultAction)
                    .disabled(binA == nil || binB == nil || running)
            }
        }
        .padding(20)
        .onChange(of: binA) { _ in summary = nil; errorText = nil }
        .onChange(of: binB) { _ in summary = nil; errorText = nil }
    }

    private func fillBoth(_ urls: [URL]) {
        if urls.count >= 2 { binA = urls[0]; binB = urls[1] }
    }

    private func compare() {
        guard let a = binA, let b = binB else { return }
        if a.standardizedFileURL == b.standardizedFileURL {
            errorText = "You chose the same bin for A and B."
            return
        }
        running = true; errorText = nil; summary = nil
        let options = engineOptions(fps: fps)
        let browser = alsoOpenInBrowser
        let saving = Prefs.bool(Prefs.autoSave, false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try runEngine(binA: a, binB: b, options: options) }
            DispatchQueue.main.async {
                running = false
                switch result {
                case .success(let s):
                    summary = s
                    savedCopy = saving
                    AppState.shared.lastError = nil
                    ColumnPrefs.shared.remember(s.columns ?? [])
                    ReportController.open(s)
                    if browser { NSWorkspace.shared.open(URL(fileURLWithPath: s.report)) }
                case .failure(let err):
                    errorText = err.localizedDescription
                    AppState.shared.lastError = err.localizedDescription
                }
            }
        }
    }
}

struct ResultBox: View {
    let summary: Summary
    var savedCopy = false

    var headline: String {
        let n = summary.clips_with_differences ?? summary.differences
        if n == 0 { return "No differences in the compared columns." }
        return "\(n) clip\(n == 1 ? "" : "s") with differences."
    }

    var breakdown: String {
        var parts = ["Durations: \(summary.differences)"]
        if let m = summary.metadata_differences { parts.append("Other columns: \(m)") }
        if let clip = summary.biggest_clip, let tc = summary.biggest_tc { parts.append("Biggest: \(clip) \(tc)") }
        return parts.joined(separator: "   ·   ")
    }

    var body: some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).bold()
                    Text(breakdown)
                    Text(details).foregroundColor(.secondary).font(.callout)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Show Report") { ReportController.open(summary) }
                    if savedCopy {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.report)])
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    var details: String {
        var parts = ["Matched by tape: \(summary.matched)",
                     "Only in A: \(summary.only_a)",
                     "Only in B: \(summary.only_b)"]
        if summary.no_tape_a + summary.no_tape_b > 0 {
            parts.append("No tape name: \(summary.no_tape_a) / \(summary.no_tape_b)")
        }
        return parts.joined(separator: "   ·   ")
    }
}

struct BinSlot: View {
    let label: String
    @Binding var url: URL?
    var onDropMany: ([URL]) -> Void
    @State private var targeted = false
    @AppStorage("lastFolder") private var lastFolder = ""

    var body: some View {
        VStack(spacing: 8) {
            Text(label).font(.headline)
            Image(systemName: url == nil ? "tray.and.arrow.down" : "doc.fill")
                .font(.system(size: 26))
                .foregroundColor(url == nil ? .secondary : .accentColor)
            if let u = url {
                Text(u.lastPathComponent).bold().lineLimit(1).truncationMode(.middle)
                Text(u.deletingLastPathComponent().lastPathComponent)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Drop a bin here").foregroundColor(.secondary)
            }
            Button(url == nil ? "Choose…" : "Change…", action: choose)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: url == nil ? [5, 4] : []))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted, perform: handleDrop)
        .help(url?.path ?? "")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(label)"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = binExtensions.compactMap { UTType(filenameExtension: $0) }
        if let u = url {
            panel.directoryURL = u.deletingLastPathComponent()
        } else if !lastFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: lastFolder)
        }
        if panel.runModal() == .OK, let picked = panel.url {
            url = picked
            lastFolder = picked.deletingLastPathComponent().path
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls = [URL]()
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { item, _ in
                if let u = item, binExtensions.contains(u.pathExtension.lowercased()) {
                    lock.lock(); urls.append(u); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { NSSound.beep(); return }
            urls.sort { $0.lastPathComponent < $1.lastPathComponent }
            if urls.count >= 2 {
                onDropMany(urls)
            } else {
                url = urls[0]
            }
            lastFolder = urls[0].deletingLastPathComponent().path
        }
        return true
    }
}
