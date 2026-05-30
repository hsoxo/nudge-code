import Foundation
import Testing
@testable import NudgeMobile

@Suite("New Tab launch preferences persistence")
@MainActor
struct AppModelLaunchPreferencesTests {
    @Test func recordLaunchPersistsLastAgentAndRecentFolder() async throws {
        let persistence = RecordingLaunchPersistence()
        let model = AppModel(persistence: persistence)

        model.recordLaunch(agent: "codex", folder: "/Users/me/Projects/app")

        #expect(model.lastLaunchAgent == "codex")
        #expect(model.recentFolders == ["/Users/me/Projects/app"])
        let saved = try #require(persistence.savedStates.last)
        #expect(saved.lastLaunchAgent == "codex")
        #expect(saved.recentFolders == ["/Users/me/Projects/app"])
    }

    @Test func recordLaunchWithBlankFolderRecordsAgentOnly() async throws {
        let persistence = RecordingLaunchPersistence()
        let model = AppModel(persistence: persistence)

        model.recordLaunch(agent: "claude", folder: nil)
        model.recordLaunch(agent: "claude", folder: "   ")

        #expect(model.lastLaunchAgent == "claude")
        #expect(model.recentFolders.isEmpty)
        #expect(persistence.savedStates.last?.recentFolders.isEmpty == true)
    }

    @Test func recentFoldersMoveToFrontDeduplicateAndCapAtFive() async throws {
        let model = AppModel()

        for path in ["/a", "/b", "/c", "/d", "/e", "/f"] {
            model.recordLaunch(agent: "shell", folder: path)
        }

        // Newest first, capped at five (oldest "/a" dropped).
        #expect(model.recentFolders == ["/f", "/e", "/d", "/c", "/b"])

        // Re-selecting an existing folder moves it to the front without growing.
        model.recordLaunch(agent: "shell", folder: "/c")
        #expect(model.recentFolders == ["/c", "/f", "/e", "/d", "/b"])
    }

    @Test func recordLaunchSkipsPersistWhenNothingChanges() async throws {
        let persistence = RecordingLaunchPersistence()
        let model = AppModel(persistence: persistence)

        model.recordLaunch(agent: "shell", folder: "/work")
        let countAfterFirst = persistence.savedStates.count

        // Same agent + same folder already at the front: no new write.
        model.recordLaunch(agent: "shell", folder: "/work")
        #expect(persistence.savedStates.count == countAfterFirst)
    }

    @Test func restoringReadsPersistedLaunchPreferences() async throws {
        let stored = AppModelStoredState(
            machines: [],
            selectedMachineID: nil,
            phoneProfile: TerminalProfile(rows: 32, cols: 48),
            recentFolders: ["/Users/me/Projects/app", "/tmp/work"],
            lastLaunchAgent: "codex"
        )

        let restored = AppModel.restoring(from: RecordingLaunchPersistence(storedState: stored))

        #expect(restored.lastLaunchAgent == "codex")
        #expect(restored.recentFolders == ["/Users/me/Projects/app", "/tmp/work"])
    }

    @Test func storedStateDecodesLegacyBlobWithoutLaunchPreferences() throws {
        // A v1 blob (pre-recents) must decode with empty defaults, not throw.
        let legacy = """
        {
            "version": 1,
            "machines": [],
            "phoneProfile": { "rows": 32, "cols": 48 },
            "terminalFontSize": 14,
            "keyboardSoundEnabled": false
        }
        """
        let data = Data(legacy.utf8)

        let decoded = try JSONDecoder().decode(AppModelStoredState.self, from: data)

        #expect(decoded.recentFolders.isEmpty)
        #expect(decoded.lastLaunchAgent == nil)
        #expect(decoded.terminalFontSize == 14)
    }

    @Test func storedStateRoundTripsLaunchPreferences() throws {
        let state = AppModelStoredState(
            machines: [],
            selectedMachineID: nil,
            phoneProfile: TerminalProfile(rows: 32, cols: 48),
            recentFolders: ["/one", "/two"],
            lastLaunchAgent: "claude"
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppModelStoredState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.recentFolders == ["/one", "/two"])
        #expect(decoded.lastLaunchAgent == "claude")
    }

    @Test func sanitizedRecentFoldersTrimsBlanksAndDuplicates() {
        let sanitized = AppModel.sanitizedRecentFolders([
            "  /a  ", "/a", "", "   ", "/b", "/c", "/d", "/e", "/f"
        ])

        // Trimmed, de-duplicated, blanks removed, capped at five.
        #expect(sanitized == ["/a", "/b", "/c", "/d", "/e"])
    }
}

@MainActor
private final class RecordingLaunchPersistence: AppModelPersistence {
    private var storedState: AppModelStoredState?
    var savedStates: [AppModelStoredState] = []

    init(storedState: AppModelStoredState? = nil) {
        self.storedState = storedState
    }

    func load() -> AppModelStoredState? {
        storedState
    }

    func save(_ state: AppModelStoredState) {
        storedState = state
        savedStates.append(state)
    }
}
