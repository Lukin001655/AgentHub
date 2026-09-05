import Foundation
import Testing

@testable import AgentHubSessionGraph

@Suite("Codex pending session candidate resolver")
struct CodexPendingSessionCandidateResolverTests {
  @Test("Recent writes do not turn an older rollout into a fresh session")
  func ignoresOlderActiveRollout() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    let pendingStartedAt = Date()
    let old = try fixture.writeSession(
      id: "old-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt.addingTimeInterval(-3_600)
    )

    let candidate = CodexPendingSessionCandidateResolver.selectCandidate(
      in: [old],
      matchingProjectRoots: [fixture.projectPath],
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: true
    )

    #expect(candidate == nil)
  }

  @Test("A rollout created during watcher startup closes the baseline race")
  func acceptsIntrinsicallyNewBaselineRollout() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    let pendingStartedAt = Date()
    let fresh = try fixture.writeSession(
      id: "fresh-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt.addingTimeInterval(0.1)
    )

    let candidate = CodexPendingSessionCandidateResolver.selectCandidate(
      in: [fresh],
      matchingProjectRoots: [fixture.projectPath],
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: true
    )

    #expect(candidate?.sessionId == "fresh-session")
  }

  @Test("A claimed rollout is skipped for another pending session")
  func skipsClaimedRollout() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    let pendingStartedAt = Date()
    let first = try fixture.writeSession(
      id: "first-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt.addingTimeInterval(0.1)
    )
    let second = try fixture.writeSession(
      id: "second-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt.addingTimeInterval(0.2)
    )

    let candidate = CodexPendingSessionCandidateResolver.selectCandidate(
      in: [first, second],
      matchingProjectRoots: [fixture.projectPath],
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: false,
      claimedSessionIds: ["second-session"]
    )

    #expect(candidate?.sessionId == "first-session")
  }

  @Test("Internal guardian and thread-spawn rollouts are never pending roots")
  func ignoresInternalRollouts() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    let pendingStartedAt = Date()
    let guardian = try fixture.writeSession(
      id: "guardian-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt,
      source: ["subagent": ["other": "guardian"]]
    )
    let threadSpawn = try fixture.writeSession(
      id: "thread-spawn-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt.addingTimeInterval(0.1),
      source: ["subagent": ["thread_spawn": ["parent_thread_id": "root"]]]
    )

    let candidate = CodexPendingSessionCandidateResolver.selectCandidate(
      in: [guardian, threadSpawn],
      matchingProjectRoots: [fixture.projectPath],
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: true
    )

    #expect(candidate == nil)
  }

  @Test("Process ownership selects the correct root for concurrent same-cwd launches")
  func processOwnershipSelectsCorrectRoot() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    let pendingStartedAt = Date()
    let first = try fixture.writeSession(
      id: "first-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt.addingTimeInterval(0.1)
    )
    let second = try fixture.writeSession(
      id: "second-session",
      cwd: fixture.projectPath,
      timestamp: pendingStartedAt.addingTimeInterval(0.2)
    )
    let inspector = MappingProcessOpenFileInspector(pathsByPID: [
      101: [first],
      202: [second]
    ])
    let resolver = CodexPendingSessionProcessResolver(openFileInspector: inspector)

    let firstCandidate = await resolver.selectCandidate(
      in: [first, second],
      matchingProjectRoots: [fixture.projectPath],
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: true,
      claimedSessionIds: [],
      owningProcessId: 101,
      requiresProcessOwnership: true
    )
    let secondCandidate = await resolver.selectCandidate(
      in: [first, second],
      matchingProjectRoots: [fixture.projectPath],
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: true,
      claimedSessionIds: [],
      owningProcessId: 202,
      requiresProcessOwnership: true
    )
    let unresolved = await resolver.selectCandidate(
      in: [first, second],
      matchingProjectRoots: [fixture.projectPath],
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: true,
      claimedSessionIds: [],
      owningProcessId: 303,
      requiresProcessOwnership: true
    )

    #expect(firstCandidate?.sessionId == "first-session")
    #expect(secondCandidate?.sessionId == "second-session")
    #expect(unresolved == nil)
  }
}

private actor MappingProcessOpenFileInspector: CodexProcessOpenFileInspecting {
  let pathsByPID: [Int32: Set<String>]

  init(pathsByPID: [Int32: Set<String>]) {
    self.pathsByPID = pathsByPID
  }

  func openFilePaths(for processId: Int32) -> Set<String> {
    pathsByPID[processId] ?? []
  }
}

private struct Fixture {
  let root: URL
  let projectPath: String

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "codex_pending_resolver_\(UUID().uuidString)", directoryHint: .isDirectory)
    projectPath = root.appending(path: "project", directoryHint: .isDirectory).path
    try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
  }

  func writeSession(
    id: String,
    cwd: String,
    timestamp: Date,
    source: Any = "cli"
  ) throws -> String {
    let path = root.appending(path: "\(id).jsonl")
    let timestampString = ISO8601DateFormatter().string(from: timestamp)
    let object: [String: Any] = [
      "timestamp": timestampString,
      "type": "session_meta",
      "payload": [
        "id": id,
        "timestamp": timestampString,
        "cwd": cwd,
        "source": source
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    try (String(decoding: data, as: UTF8.self) + "\n")
      .write(to: path, atomically: true, encoding: .utf8)
    return path.path
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
