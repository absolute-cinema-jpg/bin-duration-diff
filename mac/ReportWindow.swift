// The report, inside the app: an interactive web view of the engine's HTML report,
// with Export PDF / HTML / CSV, Print, and Open in Browser.
//
// The column checkboxes live in the report's own JavaScript; every change is posted
// back here and remembered, so the next report starts with the same columns showing.

import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

final class ReportController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let summary: Summary
    let webView: WKWebView
    private var pendingPDF: URL?

    var title: String {
        if let a = summary.bin_a, let b = summary.bin_b { return "\(a)  vs  \(b)" }
        return URL(fileURLWithPath: summary.report).deletingPathExtension().lastPathComponent
    }

    /// File name stem for exports, e.g. "Picture vs Sync".
    var exportName: String {
        func stem(_ s: String?) -> String? { s.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } }
        if let a = stem(summary.bin_a), let b = stem(summary.bin_b) { return "\(a) vs \(b)" }
        return URL(fileURLWithPath: summary.report).deletingPathExtension().lastPathComponent
    }

    init(summary: Summary) {
        self.summary = summary
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "bindiff")
        webView.navigationDelegate = self
        let url = URL(fileURLWithPath: summary.report)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // Column checkboxes changed in the report -> remember them.
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let list = body["unchecked"] as? [String] else { return }
        UserDefaults.standard.set(list, forKey: Prefs.reportUnchecked)
    }

    // Links open in the browser, not inside the report.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let u = action.request.url {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: exporting

    private func savePanel(_ name: String, _ type: UTType, _ done: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let folder = Prefs.reportsFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        panel.directoryURL = folder
        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { done(url) }
        }
        if let w = webView.window { panel.beginSheetModal(for: w, completionHandler: handle) }
        else { handle(panel.runModal()) }
    }

    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = .landscape
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 28; info.bottomMargin = 28
        info.leftMargin = 28; info.rightMargin = 28
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// Saves exactly what's on screen (ticked columns only) as a paginated PDF.
    func exportPDF() {
        savePanel(exportName + ".pdf", .pdf) { url in self.writePDF(to: url, reveal: true) }
    }

    func writePDF(to url: URL, reveal: Bool) {
        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        try? FileManager.default.removeItem(at: url)
        pendingPDF = reveal ? url : nil
        run(webView.printOperation(with: info), showPanel: false)
    }

    func printReport() {
        run(webView.printOperation(with: printInfo()), showPanel: true)
    }

    private func run(_ op: NSPrintOperation, showPanel: Bool) {
        op.showsPrintPanel = showPanel
        op.showsProgressPanel = true
        op.view?.frame = webView.bounds
        if let w = webView.window {
            op.runModal(for: w, delegate: self, didRun: #selector(printDone(_:success:contextInfo:)), contextInfo: nil)
        } else {
            _ = op.run()
        }
    }

    @objc private func printDone(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if success, let url = pendingPDF { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        pendingPDF = nil
    }

    /// The report as it is now (with the current column choices) as a standalone HTML file.
    func currentHTML(_ done: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("'<!doctype html>\\n' + document.documentElement.outerHTML") { result, _ in
            done(result as? String)
        }
    }

    func exportHTML() {
        savePanel(exportName + ".html", .html) { url in
            self.currentHTML { html in
                guard let html = html else { return }
                do {
                    try html.write(to: url, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    showAlert("Couldn't save the report", error.localizedDescription, style: .warning)
                }
            }
        }
    }

    func exportCSV() {
        guard let csv = summary.csv else { return }
        savePanel(exportName + ".csv", .commaSeparatedText) { url in
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: csv), to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                showAlert("Couldn't save the CSV", error.localizedDescription, style: .warning)
            }
        }
    }

    func openInBrowser() {
        currentHTML { html in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(self.exportName).html")
            if let html = html, (try? html.write(to: url, atomically: true, encoding: .utf8)) != nil {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: self.summary.report))
            }
        }
    }

    static func open(_ summary: Summary) {
        let controller = ReportController(summary: summary)
        Windows.show("report:" + summary.report, title: controller.title,
                     size: NSSize(width: 1120, height: 780), resizable: true) {
            ReportView(controller: controller)
        }
    }
}

/// WKUserContentController keeps a strong reference to its handlers; this breaks the cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ReportView: View {
    let controller: ReportController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Tick or untick columns under “Differences by column” to choose what the report shows.")
                    .font(.callout).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Button(action: controller.exportPDF) {
                    Label("Export PDF…", systemImage: "doc.richtext")
                }
                .keyboardShortcut("e", modifiers: [.command])
                Menu("More") {
                    Button("Print…", action: controller.printReport)
                    Button("Export HTML…", action: controller.exportHTML)
                    Button("Export CSV…", action: controller.exportCSV).disabled(controller.summary.csv == nil)
                    Divider()
                    Button("Open in Browser", action: controller.openInBrowser)
                }
                .frame(width: 80)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            WebViewHost(webView: controller.webView)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
