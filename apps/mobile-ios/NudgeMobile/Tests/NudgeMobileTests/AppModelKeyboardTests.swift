import Foundation
import Testing
@testable import NudgeMobile

@Suite("AppModel keyboard + font settings")
@MainActor
struct AppModelKeyboardTests {
    private func makePersistence() -> UserDefaultsAppModelPersistence {
        let suiteName = "dev.nudgecode.NudgeMobile.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UserDefaultsAppModelPersistence(defaults: defaults, key: "appModelState.test")
    }

    @Test func defaultsMatchExpectedSeedValues() {
        let model = AppModel()
        #expect(model.terminalFontSize == AppModel.defaultFontSize)
        #expect(model.terminalFontSize == 13)
        #expect(model.keyboardLayout == .default)
        #expect(model.keyboardSoundEnabled == false)
    }

    @Test func fontSizeClampsToRange() {
        let model = AppModel()
        model.updateFontSize(99)
        #expect(model.terminalFontSize == AppModel.maxFontSize)
        model.updateFontSize(1)
        #expect(model.terminalFontSize == AppModel.minFontSize)
        #expect(AppModel.minFontSize == 10)
        #expect(AppModel.maxFontSize == 20)
    }

    @Test func fontSizeKeyboardAndSoundPersistAndRestore() {
        let persistence = makePersistence()
        let model = AppModel(persistence: persistence)

        model.updateFontSize(17)
        model.setKeyboardSoundEnabled(true)
        var layout = KeyboardLayout.default
        layout.rows.append([KeyboardKey(label: "wq", send: ":wq", autoEnter: true, grow: 2)])
        model.updateKeyboardLayout(layout)

        let restored = AppModel.restoring(from: persistence)
        #expect(restored.terminalFontSize == 17)
        #expect(restored.keyboardSoundEnabled == true)
        #expect(restored.keyboardLayout == layout)
        #expect(restored.keyboardLayout.rows.last?.first?.send == ":wq")
    }

    @Test func restoreDefaultKeyboardResetsLayout() {
        let model = AppModel()
        var layout = KeyboardLayout.default
        layout.rows = [[KeyboardKey(label: "x", send: "x")]]
        model.updateKeyboardLayout(layout)
        #expect(model.keyboardLayout != .default)

        model.restoreDefaultKeyboardLayout()
        #expect(model.keyboardLayout == .default)
    }
}
