import Foundation
import SwiftProtobuf
import Testing
@testable import NudgeMobile

@Suite("Generated protocol")
struct GeneratedProtocolTests {
    @Test func sessionStateRoundTripsThroughGeneratedProtobuf() throws {
        var state = Nudge_V1_SessionState()
        var tab = Nudge_V1_Tab()
        tab.id = "default"
        tab.title = "claude"
        tab.status = "running"
        tab.widthMode = "phone"
        tab.rows = 24
        tab.cols = 80
        var agent = Nudge_V1_AgentStatus()
        agent.kind = "claude"
        agent.state = "needs_approval"
        agent.confidence = 0.82
        agent.source = "screen"
        tab.agentStatus = agent
        state.tabs = [tab]

        let encoded = try state.serializedData()
        let decoded = try Nudge_V1_SessionState(serializedBytes: encoded)

        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs[0].id == "default")
        #expect(decoded.tabs[0].agentStatus.kind == "claude")
        #expect(decoded.tabs[0].agentStatus.state == "needs_approval")
    }

    @Test func encryptedEnvelopeRoundTripsThroughGeneratedProtobuf() throws {
        var envelope = Nudge_V1_E2EEncryptedEnvelope()
        envelope.sessionID = "session-1"
        envelope.senderDeviceID = "phone_1"
        envelope.recipientDeviceID = "daemon_1"
        envelope.messageType = "terminal_input"
        envelope.sequence = 7
        envelope.nonce = Data([1, 2, 3])
        envelope.ciphertext = Data([4, 5, 6])

        var outer = Nudge_V1_Envelope()
        outer.messageID = "msg-1"
        outer.e2EEncryptedEnvelope = envelope

        let encoded = try outer.serializedData()
        let decoded = try Nudge_V1_Envelope(serializedBytes: encoded)

        #expect(decoded.messageID == "msg-1")
        #expect(decoded.e2EEncryptedEnvelope.sessionID == "session-1")
        #expect(decoded.e2EEncryptedEnvelope.sequence == 7)
        #expect(decoded.e2EEncryptedEnvelope.ciphertext == Data([4, 5, 6]))
    }

    @Test func rotateDeviceKeyRoundTripsThroughGeneratedProtobuf() throws {
        var outer = Nudge_V1_Envelope()
        outer.messageID = "rotate-1"
        outer.rotateDeviceKey = Nudge_V1_RotateDeviceKey()

        let encoded = try outer.serializedData()
        let decoded = try Nudge_V1_Envelope(serializedBytes: encoded)

        #expect(decoded.messageID == "rotate-1")
        guard case .rotateDeviceKey? = decoded.payload else {
            Issue.record("expected rotate_device_key payload")
            return
        }
    }
}
