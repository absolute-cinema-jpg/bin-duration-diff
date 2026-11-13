// Checks GitHub for a newer release and installs it in place.
//
// Releases live at https://github.com/<AppInfo.repo>/releases. Each release is tagged
// vX.Y.Z and has the app zip (from build_app.sh) attached. The installer downloads
// the zip, checks the app inside has this app's bundle ID and a newer version, then a
// tiny shell script swaps it in after we quit and relaunches it.

import SwiftUI
import AppKit

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int?
    }
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: String
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var zipAsset: Asset? { assets.first { $0.name.lowercased().hasSuffix(".zip") } }
}

final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var busy = false
    @Published var status = ""
    private let lastCheckKey = "lastUpdateCheck"

    // MARK: version maths

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: checking

    func checkAutomaticallyIfDue() {
        guard Prefs.bool(Prefs.autoUpdate, true) else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        check(userInitiated: false)
    }

    static func fetchLatest(_ done: @escaping (Result<GitHubRelease, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BinDurationDiff/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return done(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data = data else {
                let msg = code == 404 ? "No releases have been published yet." : "GitHub returned an error (\(code))."
                return done(.failure(EngineError.message(msg)))
            }
            done(Result { try JSONDecoder().decode(GitHubRelease.self, from: data) })
        }.resume()
    }

    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        status = "Checking…"
        Updater.fetchLatest { result in
            DispatchQueue.main.async {
                self.busy = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                switch result {
                case .failure(let err):
                    self.status = "Couldn't check: \(err.localizedDescription)"
                    if userInitiated {
                        showAlert("Couldn't check for updates", err.localizedDescription, style: .warning)
                    }
                case .success(let rel):
                    if Updater.isNewer(rel.version, than: AppInfo.version) {
                        self.status = "Version \(rel.version) is available."
                        self.offer(rel)
                    } else {
                        self.status = "You're up to date."
                        if userInitiated {
                            showAlert("You're up to date", "Bin Duration Diff \(AppInfo.version) is the latest version.")
                        }
                    }
                }
            }
        }
    }

    private func offer(_ rel: GitHubRelease) {
        let a = NSAlert()
        a.messageText = "Bin Duration Diff \(rel.version) is available"
        var notes = (rel.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        a.informativeText = "You have version \(AppInfo.version)." + (notes.isEmpty ? "" : "\n\nWhat's new:\n\(notes)")
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "View Release")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: install(rel)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(URL(string: rel.html_url)!)
        default: break
        }
    }

    // MARK: installing

    /// Why the running app can't be replaced in place, if it can't.
    static func installBlocker() -> String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running the app from a temporary location. Move Bin Duration Diff into your Applications folder, open it from there, then try again."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "You don't have permission to replace the app in \(app.deletingLastPathComponent().path)."
        }
        return nil
    }

    private func install(_ rel: GitHubRelease) {
        if let why = Updater.installBlocker() {
            showAlert("Can't install the update automatically", why + "\n\nThe release page will open so you can download it yourself.", style: .warning)
            NSWorkspace.shared.open(URL(string: rel.html_url)!)
            return
        }
        guard let asset = rel.zipAsset else {
            NSWorkspace.shared.open(URL(string: rel.html_url)!)
            return
        }
        busy = true
        status = "Downloading \(rel.version)…"
        Windows.show("update", title: "Updating", size: NSSize(width: 360, height: 110)) {
            UpdateProgressView(updater: self)
        }
        Updater.download(asset) { result in
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .failure(let err):
                    Windows.close("update")
                    self.status = "Update failed."
                    showAlert("The update couldn't be installed", err.localizedDescription, style: .warning)
                case .success(let newApp):
                    self.status = "Restarting…"
                    do {
                        try Updater.swapAndRelaunch(newApp: newApp)
                        NSApp.terminate(nil)
                    } catch {
                        Windows.close("update")
                        showAlert("The update couldn't be installed", error.localizedDescription, style: .warning)
                    }
                }
            }
        }
    }

    /// Downloads and unpacks a release zip; returns the new .app after checking it.
    static func download(_ asset: GitHubRelease.Asset, _ done: @escaping (Result<URL, Error>) -> Void) {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinDurationDiffUpdate-\(UUID().uuidString)", isDirectory: true)
        var req = URLRequest(url: URL(string: asset.browser_download_url)!)
        req.setValue("BinDurationDiff/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            done(Result {
                if let err = err { throw err }
                guard let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw EngineError.message("The download failed.")
                }
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tmp, to: zip)
                let unzipped = work.appendingPathComponent("unzipped", isDirectory: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, unzipped.path]
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw EngineError.message("The download couldn't be unzipped.") }
                return try findApp(in: unzipped)
            })
        }.resume()
    }

    static func findApp(in folder: URL) throws -> URL {
        let fm = FileManager.default
        var candidates = [URL]()
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            if item.pathExtension == "app" { candidates.append(item) }
            else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                candidates += ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "app" }
            }
        }
        for app in candidates {
            if let b = Bundle(url: app), b.bundleIdentifier == Bundle.main.bundleIdentifier {
                return app
            }
        }
        throw EngineError.message("The download doesn't contain Bin Duration Diff.")
    }

    /// Starts a helper that waits for us to quit, swaps the app, and relaunches it.
    static func swapAndRelaunch(newApp: URL, target: URL = Bundle.main.bundleURL,
                                pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                relaunch: Bool = true) throws {
        let script = """
        PID="$1"; NEW="$2"; DEST="$3"; RELAUNCH="$4"; WORK="$5"
        for i in $(seq 1 300); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        BACKUP="$DEST.updating-$$"
        if mv "$DEST" "$BACKUP" && /usr/bin/ditto "$NEW" "$DEST"; then
          rm -rf "$BACKUP"
        else
          rm -rf "$DEST"; mv "$BACKUP" "$DEST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        [ -n "$WORK" ] && rm -rf "$WORK"
        [ "$RELAUNCH" = "1" ] && /usr/bin/open "$DEST"
        exit 0
        """
        // The temporary download folder, cleaned up afterwards (only ever our own temp folder).
        var work = newApp.deletingLastPathComponent()
        while work.path != "/" && !work.lastPathComponent.hasPrefix("BinDurationDiffUpdate-") {
            work = work.deletingLastPathComponent()
        }
        let workPath = work.lastPathComponent.hasPrefix("BinDurationDiffUpdate-") ? work.path : ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "updater", String(pid), newApp.path, target.path, relaunch ? "1" : "0", workPath]
        try p.run()
    }
}

struct UpdateProgressView: View {
    @ObservedObject var updater: Updater
    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(updater.status)
            Spacer()
        }
        .padding(24)
        .frame(width: 360, height: 110)
    }
}
