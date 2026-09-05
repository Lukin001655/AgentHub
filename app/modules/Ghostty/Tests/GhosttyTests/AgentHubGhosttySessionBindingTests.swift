import Testing

@testable import Ghostty

@Suite("AgentHub Ghostty session binding")
struct AgentHubGhosttySessionBindingTests {
  @Test("Pending context transfer updates a late process registration ID")
  func pendingTransferUpdatesConfiguredSessionID() {
    let resolved = AgentHubGhosttyTerminalSurface.resolvedConfiguredSessionId(
      configuredSessionId: "pending-123",
      previousTerminalKey: "pending-123",
      newTerminalKey: "session-123"
    )

    #expect(resolved == "session-123")
  }

  @Test("Unrelated context updates do not rewrite the configured session ID")
  func unrelatedContextDoesNotRewriteConfiguredSessionID() {
    let resolved = AgentHubGhosttyTerminalSurface.resolvedConfiguredSessionId(
      configuredSessionId: "session-original",
      previousTerminalKey: "session-original",
      newTerminalKey: "session-other"
    )

    #expect(resolved == "session-original")
  }
}
