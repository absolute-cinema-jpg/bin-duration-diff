// "Report a Bug": fills in a new GitHub issue on the repo and opens it in the browser.
// GitHub issues on a public repo are public, so nothing about the bins is added
// automatically -- the technical details are shown and editable before sending.

import SwiftUI
import AppKit

struct BugReportView: View {
    static func open() {
        Windows.show("bug", title: "Report a Bug", size: NSSize(width: 560, height: 560), resizable: true) {
            BugReportView()
        }
    }

    @State private var summary = ""
    @State private var happened = ""
    @State private var expected = ""
    @State private var includeDetails = true
    @State private var details = BugReportView.technicalDetails()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tell us what went wrong").font(.title3).bold()
            Text("This opens a new issue on GitHub in your browser, ready to submit (you'll need a free GitHub account). Issues are public, so please don't include confidential project, bin or clip names.")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("Short summary, e.g. “Report shows wrong durations for 25 fps bins”", text: $summary)

            Text("What happened?").bold()
            editor($happened, minHeight: 90)
            Text("What did you expect to happen? (optional)").bold()
            editor($expected, minHeight: 50)

            Toggle("Include technical details (you can edit them)", isOn: $includeDetails)
            if includeDetails {
                editor($details, minHeight: 80).font(.system(.caption, design: .monospaced))
            }

            HStack {
                Spacer()
                Button("Cancel") { Windows.close("bug") }
                    .keyboardShortcut(.cancelAction)
                Button("Open on GitHub", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty
                              && happened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 520)
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .frame(minHeight: minHeight)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
    }

    static func technicalDetails() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var arch = "unknown"
        #if arch(arm64)
        arch = "Apple Silicon"
        #elseif arch(x86_64)
        arch = "Intel"
        #endif
        var lines = [
            "App version: \(AppInfo.version)",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Mac: \(arch)",
        ]
        if let err = AppState.shared.lastError {
            lines.append("Last error: \(scrubPaths(err))")
        }
        return lines.joined(separator: "\n")
    }

    /// Replace folder paths with "…/" so error messages don't leak project folder names.
    static func scrubPaths(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(/[^/\\s:]+)+/") else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "…/")
    }

    static func issueURL(title: String, body: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var b = body
        if b.count > 5000 { b = String(b.prefix(5000)) + "\n…(trimmed)" }
        let s = "https://github.com/\(AppInfo.repo)/issues/new?labels=bug&title=\(enc(title))&body=\(enc(b))"
        return URL(string: s)!
    }

    private func send() {
        var title = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = String(happened.split(separator: "\n").first ?? "Bug report").prefix(80).description }
        var body = "### What happened\n\(happened.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        let exp = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !exp.isEmpty { body += "\n### What I expected\n\(exp)\n" }
        if includeDetails { body += "\n### Technical details\n```\n\(details)\n```\n" }
        body += "\n_Sent from Bin Diff's Report a Bug window._"
        NSWorkspace.shared.open(BugReportView.issueURL(title: title, body: body))
        Windows.close("bug")
    }
}
