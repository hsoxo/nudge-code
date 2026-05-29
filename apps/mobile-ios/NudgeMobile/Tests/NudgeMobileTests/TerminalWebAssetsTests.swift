import Foundation
import Testing
@testable import NudgeMobile

@Suite("Terminal web assets")
struct TerminalWebAssetsTests {
    @Test func xtermRuntimeAssetsAreBundled() {
        #expect(TerminalWebAssets.missingFiles(in: .main).isEmpty)
    }

    @Test func requiredFilesIncludeXtermRuntime() {
        #expect(TerminalWebAssets.requiredFilenames.contains("index.html"))
        #expect(TerminalWebAssets.requiredFilenames.contains("xterm.js"))
        #expect(TerminalWebAssets.requiredFilenames.contains("xterm.css"))
        #expect(TerminalWebAssets.requiredFilenames.contains("XTERM_LICENSE"))
    }

    @Test func terminalRendererSupportsProfileSizedComputerWidth() throws {
        let url = try #require(TerminalWebAssets.indexURL())
        let html = try String(contentsOf: url, encoding: .utf8)

        #expect(html.contains("setSnapshot(text, widthMode, rows, cols)"))
        #expect(html.contains("term.resize(safeCols, safeRows)"))
        #expect(html.contains("--terminal-width"))
        #expect(html.contains("followCursor(widthMode)"))
    }

    @Test func terminalRendererReportsMeasuredPhoneProfile() throws {
        let url = try #require(TerminalWebAssets.indexURL())
        let html = try String(contentsOf: url, encoding: .utf8)

        #expect(html.contains("measuredPhoneProfile()"))
        #expect(html.contains("messageHandlers?.phoneProfile?.postMessage(profile)"))
        #expect(html.contains("new ResizeObserver(schedulePhoneProfileReport).observe(container)"))
    }
}
