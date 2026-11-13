// Runs the bundled Python engine (Contents/Resources/engine/bin_diff_engine).

import Foundation

struct Summary: Decodable {
    let differences: Int
    let matched: Int
    let only_a: Int
    let only_b: Int
    let no_tape_a: Int
    let no_tape_b: Int
    let biggest_clip: String?
    let biggest_tc: String?
    let biggest_frames: Int?
    let report: String
    let csv: String?
    // Added in 2.0 (optional so an older engine's output still decodes)
    let clips_with_differences: Int?
    let metadata_differences: Int?
    let columns: [String]?
    let columns_only_a: [String]?
    let columns_only_b: [String]?
    // Added in 2.1
    let bin_a: String?
    let bin_b: String?
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Settings -> command-line options for bin_diff.py.
func engineOptions(fps: String) -> [String] {
    var args = ["--fps", fps]
    let tol = UserDefaults.standard.integer(forKey: Prefs.tolerance)
    if tol > 0 { args += ["--tolerance", String(tol)] }
    if Prefs.bool(Prefs.caseSensitive, false) { args.append("--case-sensitive") }
    if Prefs.bool(Prefs.includeSubclips, false) { args.append("--include-subclips") }
    // The CSV is always made (for Export CSV) unless reports are auto-saved without one.
    if Prefs.bool(Prefs.autoSave, false) && !Prefs.bool(Prefs.writeCSV, true) { args.append("--no-csv") }
    let unchecked = (UserDefaults.standard.stringArray(forKey: Prefs.reportUnchecked) ?? []).filter { !$0.contains(",") }
    if !unchecked.isEmpty { args += ["--unchecked", unchecked.joined(separator: ",")] }
    if Prefs.bool(Prefs.ignoreValueCase, false) { args.append("--ignore-value-case") }
    let ignored = ColumnPrefs.shared.ignored.filter { !$0.contains(",") }
    if !ignored.isEmpty { args += ["--ignore-columns", ignored.joined(separator: ",")] }
    let hide = ReportParts.defaultOn.filter { !ReportParts.isOn($0) }
    let show = ReportParts.defaultOff.filter { ReportParts.isOn($0) }
    if !hide.isEmpty { args += ["--hide", hide.joined(separator: ",")] }
    if !show.isEmpty { args += ["--show", show.joined(separator: ",")] }
    return args
}

/// `options` comes from engineOptions(fps:), read on the main thread.
func runEngine(binA: URL, binB: URL, options: [String]) throws -> Summary {
    guard let engine = Bundle.main.resourceURL?.appendingPathComponent("engine/bin_diff_engine"),
          FileManager.default.isExecutableFile(atPath: engine.path) else {
        throw EngineError.message("The comparison engine is missing from the app. Rebuild it with build_app.sh.")
    }

    let stamp: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f.string(from: Date())
    }()
    let name = "\(binA.deletingPathExtension().lastPathComponent) vs \(binB.deletingPathExtension().lastPathComponent) \(stamp).html"
    // Auto-saved reports go to the reports folder; otherwise to a work folder the app tidies.
    let folder = Prefs.bool(Prefs.autoSave, false) ? Prefs.reportsFolderURL : Prefs.workFolderURL
    let out = folder.appendingPathComponent(name)

    let p = Process()
    p.executableURL = engine
    p.arguments = [binA.path, binB.path, "-o", out.path, "--json"] + options
    let stdout = Pipe(), stderr = Pipe()
    p.standardOutput = stdout
    p.standardError = stderr
    try p.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()

    if p.terminationStatus != 0 {
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Python tracebacks: show just the last line.
        let msg = err.contains("Traceback") ? (err.components(separatedBy: "\n").last ?? err) : err
        throw EngineError.message(msg.isEmpty ? "The comparison failed (code \(p.terminationStatus))." : msg)
    }
    let lastLine = String(data: outData, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
    do {
        return try JSONDecoder().decode(Summary.self, from: Data(lastLine.utf8))
    } catch {
        throw EngineError.message("Couldn't read the engine's result.")
    }
}
