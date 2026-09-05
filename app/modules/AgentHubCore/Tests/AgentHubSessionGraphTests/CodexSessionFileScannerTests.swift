import Foundation
import Testing

@testable import AgentHubSessionGraph

@Suite("CodexSessionFileScanner")
struct CodexSessionFileScannerTests {
  @Test("Reads session metadata when the first JSONL line exceeds sixteen kilobytes")
  func readsOversizedSessionMetaLine() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "55555555-5555-5555-5555-555555555555"
    let projectPath = "/tmp/oversized-project"
    let sessionFile = root.appending(path: "session.jsonl")

    try oversizedCodexSessionFileContents(
      sessionID: sessionID,
      cwd: projectPath,
      branch: "feature/oversized-meta",
      baseInstructionsLength: 24_000
    )
    .write(to: sessionFile, atomically: true, encoding: .utf8)

    let meta = try #require(CodexSessionFileScanner.readSessionMeta(from: sessionFile.path))

    #expect(meta.sessionId == sessionID)
    #expect(meta.projectPath == projectPath)
    #expect(meta.branch == "feature/oversized-meta")
    #expect(meta.sessionFilePath == sessionFile.path)
    #expect(meta.source == .missing)
    #expect(meta.isUserFacingRoot)

    let expectedDate = iso8601Date("2026-05-05T12:00:00.000Z")
    #expect(meta.startedAt == expectedDate)
  }

  @Test("Distinguishes root CLI sessions from internal Codex rollouts")
  func readsSessionSource() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let cliFile = root.appending(path: "cli.jsonl")
    try codexSessionFileContents(
      sessionID: "cli-session",
      cwd: "/tmp/project",
      source: "cli"
    ).write(to: cliFile, atomically: true, encoding: .utf8)

    let guardianFile = root.appending(path: "guardian.jsonl")
    try codexSessionFileContents(
      sessionID: "guardian-session",
      cwd: "/tmp/project",
      source: ["subagent": ["other": "guardian"]]
    ).write(to: guardianFile, atomically: true, encoding: .utf8)

    let cli = try #require(CodexSessionFileScanner.readSessionMeta(from: cliFile.path))
    let guardian = try #require(CodexSessionFileScanner.readSessionMeta(from: guardianFile.path))

    #expect(cli.source == .cli)
    #expect(cli.isFreshInteractiveRoot)
    #expect(cli.isUserFacingRoot)
    #expect(guardian.source == .subagent)
    #expect(!guardian.isFreshInteractiveRoot)
    #expect(!guardian.isUserFacingRoot)
  }
}

private func iso8601Date(_ string: String) -> Date? {
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractionalFormatter.date(from: string) {
    return date
  }

  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: string)
}

private func oversizedCodexSessionFileContents(
  sessionID: String,
  cwd: String,
  branch: String,
  baseInstructionsLength: Int
) -> String {
  let sessionMeta: [String: Any] = [
    "timestamp": "2026-05-05T12:00:00.000Z",
    "type": "session_meta",
    "payload": [
      "id": sessionID,
      "timestamp": "2026-05-05T12:00:00.000Z",
      "cwd": cwd,
      "git": [
        "branch": branch
      ],
      "base_instructions": [
        "text": String(repeating: "x", count: baseInstructionsLength)
      ]
    ]
  ]
  let userMessage: [String: Any] = [
    "timestamp": "2026-05-05T12:00:01.000Z",
    "type": "event_msg",
    "payload": [
      "type": "user_message",
      "message": "hello"
    ]
  ]

  return """
  \(jsonLine(sessionMeta))
  \(jsonLine(userMessage))

  """
}

private func codexSessionFileContents(
  sessionID: String,
  cwd: String,
  source: Any
) -> String {
  jsonLine([
    "timestamp": "2026-09-02T12:00:00.000Z",
    "type": "session_meta",
    "payload": [
      "id": sessionID,
      "timestamp": "2026-09-02T12:00:00.000Z",
      "cwd": cwd,
      "source": source
    ]
  ]) + "\n"
}

private func jsonLine(_ object: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: object)
  return String(decoding: data, as: UTF8.self)
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "codex_session_file_scanner_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
