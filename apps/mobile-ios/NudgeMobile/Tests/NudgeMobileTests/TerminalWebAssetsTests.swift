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
}
