import Foundation
import Testing
@testable import NudgeMobile

@Suite("Binding draft parsing")
struct BindingDraftTests {
    @Test func parsesPairingURL() throws {
        let url = try #require(URL(string: "https://nudgecode.dev/pair?code=abc123"))
        let draft = try #require(BindingDraft(pairingURL: url))

        #expect(draft.code == "abc123")
        #expect(draft.relayURL.absoluteString == "https://nudgecode.dev")
    }

    @Test func parsesAppPairingURL() throws {
        let url = try #require(URL(string: "nudge://pair?relay=https%3A%2F%2Frelay.example.com%3A8443&code=abc123"))
        let draft = try #require(BindingDraft(pairingURL: url))

        #expect(draft.code == "abc123")
        #expect(draft.relayURL.absoluteString == "https://relay.example.com:8443")
    }

    @Test func rejectsUnrelatedURL() throws {
        let url = try #require(URL(string: "https://nudgecode.dev/other?code=abc123"))

        #expect(BindingDraft(pairingURL: url) == nil)
    }

    @Test func rejectsAppPairingURLWithoutRelay() throws {
        let url = try #require(URL(string: "nudge://pair?code=abc123"))

        #expect(BindingDraft(pairingURL: url) == nil)
    }
}
