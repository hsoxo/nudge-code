import Foundation

enum TerminalWebAssets {
    static let subdirectory = "TerminalWeb"
    static let requiredFilenames = [
        "index.html",
        "xterm.css",
        "xterm.js",
        "XTERM_LICENSE"
    ]

    static func missingFiles(in bundle: Bundle = .main) -> [String] {
        requiredFilenames.filter { filename in
            let parts = filename.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return bundle.url(
                    forResource: parts[0],
                    withExtension: parts[1],
                    subdirectory: subdirectory
                ) == nil
            }
            return bundle.url(
                forResource: filename,
                withExtension: nil,
                subdirectory: subdirectory
            ) == nil
        }
    }

    static func indexURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "index", withExtension: "html", subdirectory: subdirectory)
    }
}
