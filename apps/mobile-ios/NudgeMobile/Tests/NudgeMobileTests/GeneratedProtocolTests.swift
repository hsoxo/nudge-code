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
}
