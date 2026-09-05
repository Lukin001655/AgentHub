import Foundation
import Testing

@testable import AgentHubCore

@Suite("CodexSearchService")
struct CodexSearchServiceTests {
  @Test("Search excludes internal Codex rollouts")
  func searchExcludesInternalRollouts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "codex_search_\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionsDir = root.appending(path: "sessions/2026/09/05", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    try sessionMeta(
      id: "user-root",
      cwd: "/tmp/user-visible-root",
      source: "cli"
    ).write(
      to: sessionsDir.appending(path: "root.jsonl"),
      atomically: true,
      encoding: .utf8
    )
    try sessionMeta(
      id: "internal-guardian",
      cwd: "/tmp/internal-hidden-needle",
      source: ["subagent": ["other": "guardian"]]
    ).write(
      to: sessionsDir.appending(path: "guardian.jsonl"),
      atomically: true,
      encoding: .utf8
    )

    let service = CodexSearchService(codexDataPath: root.path)

    #expect(await service.indexedSessionCount() == 0)
    #expect(await service.search(query: "user-visible-root").map(\.id) == ["user-root"])
    #expect(await service.indexedSessionCount() == 1)
    #expect(await service.search(query: "internal-hidden-needle").isEmpty)
  }
}

private func sessionMeta(id: String, cwd: String, source: Any) -> String {
  let meta: [String: Any] = [
    "timestamp": "2026-09-05T12:00:00.000Z",
    "type": "session_meta",
    "payload": [
      "id": id,
      "timestamp": "2026-09-05T12:00:00.000Z",
      "cwd": cwd,
      "source": source,
      "git": ["branch": "main"]
    ]
  ]
  let data = try! JSONSerialization.data(withJSONObject: meta)
  return String(decoding: data, as: UTF8.self) + "\n"
}
