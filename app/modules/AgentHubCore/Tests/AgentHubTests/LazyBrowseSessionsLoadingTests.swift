import Combine
import Foundation
import AgentHubSessionGraph
import Testing

@testable import AgentHubCore

@Suite("Lazy browse session loading")
@MainActor
struct LazyBrowseSessionsLoadingTests {

  @Test("Launch restores shells and monitored sessions without full browse scan")
  func launchRestoresMonitoredSessionsWithoutFullScan() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"],
        expansionState: ["repo:/tmp/project": true]
      ),
      for: .claude
    )

    let session = CLISession(
      id: "session-1",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "first",
      sessionFilePath: "/tmp/session-1.jsonl"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      sessionsById: ["session-1": session]
    )
    let watcher = RecordingFileWatcher()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.monitoredSessions.count == 1
    }

    let calls = await monitor.calls()
    #expect(calls.restoreSkeletonCount == 1)
    #expect(calls.addRepositoriesCount == 0)
    #expect(calls.refreshCount == 0)
    #expect(calls.loadSessionRequests == [Set(["session-1"])])
    #expect(viewModel.selectedRepositories.map(\.path) == ["/tmp/project"])
    #expect(viewModel.monitoredSessions.first?.session.id == "session-1")
    #expect(await watcher.startedSessionIds() == ["session-1"])
  }

  @Test("Codex launch restore defers file watching until a session is selected")
  func codexLaunchRestoreDefersFileWatchingUntilSessionSelection() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1", "session-2"]
      ),
      for: .codex
    )

    let firstSession = CLISession(
      id: "session-1",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "first",
      sessionFilePath: "/tmp/session-1.jsonl"
    )
    let secondSession = CLISession(
      id: "session-2",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "second",
      sessionFilePath: "/tmp/session-2.jsonl"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [firstSession, secondSession])],
      sessionsById: [
        "session-1": firstSession,
        "session-2": secondSession
      ]
    )
    let watcher = RecordingFileWatcher()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.monitoredSessions.count == 2
    }

    #expect((await watcher.startedSessionIds()).isEmpty)

    viewModel.ensureLiveMonitoring(sessionId: "session-1")
    viewModel.ensureLiveMonitoring(sessionId: "session-1")
    await waitUntilAsync {
      await watcher.startedSessionIds() == ["session-1"]
    }

    viewModel.ensureLiveMonitoring(sessionId: "session-2")
    await waitUntilAsync {
      await watcher.startedSessionIds() == ["session-1", "session-2"]
    }
  }

  @Test("Launch restore syncs Claude hooks once for restored repo and worktree paths")
  func launchRestoreSyncsClaudeHooksOnce() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        ownedWorktreePaths: ["/tmp/project-feature"]
      ),
      for: .claude
    )

    let restoredRepository = repositoryWithWorktree(
      path: "/tmp/project",
      worktreePath: "/tmp/project-feature"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [restoredRepository],
      browseRepositories: [restoredRepository]
    )
    let hookInstaller = RecordingClaudeHookInstaller()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService(),
      hookInstaller: hookInstaller
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    await waitUntilAsync {
      await hookInstaller.syncRequests().count == 1
    }

    #expect(await hookInstaller.syncRequests() == [
      Set(["/tmp/project", "/tmp/project-feature"])
    ])
  }

  @Test("Idle repository changes still trigger Claude hook sync", .disabled("headless-quarantine: async propagation timing; see TestQuarantine.md"))
  func idleRepositoryChangesTriggerClaudeHookSync() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    let repository = repositoryWithWorktree(
      path: "/tmp/project",
      worktreePath: "/tmp/project-feature"
    )
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        ownedWorktreePaths: ["/tmp/project-feature"]
      ),
      for: .claude
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository],
      browseRepositories: [repository]
    )
    let hookInstaller = RecordingClaudeHookInstaller()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService(),
      hookInstaller: hookInstaller
    )

    try await Task.sleep(for: .milliseconds(50))
    let baselineCount = await hookInstaller.syncRequests().count

    await monitor.setSelectedRepositories([repository])

    await waitUntilAsync {
      await hookInstaller.syncRequests().count == baselineCount + 1
    }
    #expect(viewModel.selectedRepositories.map(\.path) == ["/tmp/project"])
    #expect(await hookInstaller.syncRequests().last == Set(["/tmp/project", "/tmp/project-feature"]))
  }

  @Test("Launch targeted restore skips sessions outside restored roots")
  func launchTargetedRestoreSkipsSessionsOutsideRestoredRoots() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["orphan-session", "session-1"]
      ),
      for: .claude
    )

    let session = CLISession(
      id: "session-1",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "first",
      sessionFilePath: "/tmp/session-1.jsonl"
    )
    let orphan = CLISession(
      id: "orphan-session",
      projectPath: "/tmp/deleted-worktree",
      branchName: "feature",
      firstMessage: "orphan",
      sessionFilePath: "/tmp/orphan-session.jsonl"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      sessionsById: [
        "orphan-session": orphan,
        "session-1": session
      ]
    )
    let watcher = RecordingFileWatcher()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.monitoredSessions.count == 1
    }

    let calls = await monitor.calls()
    #expect(calls.loadSessionRequests == [Set(["orphan-session", "session-1"])])
    #expect(viewModel.isMonitoring(sessionId: "session-1"))
    #expect(!viewModel.isMonitoring(sessionId: "orphan-session"))
    #expect(Set(viewModel.monitoredSessions.map(\.session.id)) == ["session-1"])
    #expect(await watcher.startedSessionIds() == ["session-1"])
  }

  @Test("Removing repository stops monitored sessions restored before browse load")
  func removingRepositoryStopsRestoredBackupSessionsBeforeBrowseLoad() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"]
      ),
      for: .claude
    )

    let session = CLISession(
      id: "session-1",
      projectPath: "/tmp/project",
      branchName: "main",
      firstMessage: "first",
      sessionFilePath: "/tmp/session-1.jsonl"
    )
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      sessionsById: ["session-1": session]
    )
    let watcher = RecordingFileWatcher()

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.monitoredSessions.count == 1
    }

    let repository = try #require(viewModel.selectedRepositories.first)
    #expect(repository.totalSessionCount == 0)

    viewModel.removeRepository(repository)

    #expect(!viewModel.isMonitoring(sessionId: "session-1"))
    await waitUntilAsync {
      await watcher.stoppedSessionIds() == ["session-1"]
    }
  }

  @Test("Browse request during repository restore scans after repositories arrive")
  func browseRequestDuringRepositoryRestoreScansAfterRepositoriesArrive() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(selectedRepositoryPaths: ["/tmp/project"]),
      for: .codex
    )

    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])],
      restoreSkeletonDelay: .milliseconds(150)
    )

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    viewModel.ensureBrowseSessionsLoaded()
    #expect(viewModel.browseSessionsLoadState == .loading)

    try await Task.sleep(for: .milliseconds(50))
    var calls = await monitor.calls()
    #expect(calls.refreshCount == 0)

    await waitUntil { viewModel.browseSessionsLoadState == .loaded }

    calls = await monitor.calls()
    #expect(calls.restoreSkeletonCount == 1)
    #expect(calls.refreshCount == 1)
    #expect(viewModel.allSessions.map(\.id) == ["session-1"])
  }

  @Test("Browse load scans once, then manual refresh scans again")
  func browseLoadScansOnceThenManualRefreshScansAgain() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(selectedRepositoryPaths: ["/tmp/project"]),
      for: .codex
    )

    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])]
    )

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    #expect(viewModel.browseSessionsLoadState == .notLoaded)

    viewModel.ensureBrowseSessionsLoaded()
    await waitUntil { viewModel.browseSessionsLoadState == .loaded }

    var calls = await monitor.calls()
    #expect(calls.refreshCount == 1)
    #expect(viewModel.allSessions.map(\.id) == ["session-1"])

    viewModel.ensureBrowseSessionsLoaded()
    try await Task.sleep(for: .milliseconds(50))
    calls = await monitor.calls()
    #expect(calls.refreshCount == 1)

    viewModel.refreshBrowseSessions()
    await waitUntil { viewModel.browseSessionsLoadState == .loaded }
    calls = await monitor.calls()
    #expect(calls.refreshCount == 2)
  }

  @Test("Duplicate add keeps Browse not loaded")
  func duplicateAddKeepsBrowseNotLoaded() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(selectedRepositoryPaths: ["/tmp/project"]),
      for: .codex
    )

    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    let monitor = LazyBrowseMockMonitorService(
      skeletonRepositories: [repository(path: "/tmp/project")],
      browseRepositories: [repository(path: "/tmp/project", sessions: [session])]
    )

    let viewModel = CLISessionsViewModel(
      monitorService: monitor,
      fileWatcher: RecordingFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await waitUntil {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    #expect(viewModel.browseSessionsLoadState == .notLoaded)

    viewModel.addRepository(at: "/tmp/project")
    await waitUntilAsync {
      let calls = await monitor.calls()
      return calls.addRepositoriesCount == 1
    }
    await waitUntil { viewModel.loadingState == .idle }

    let calls = await monitor.calls()
    #expect(calls.refreshCount == 0)
    #expect(viewModel.browseSessionsLoadState == .notLoaded)
    #expect(viewModel.allSessions.isEmpty)
  }

  @Test("Claude targeted restore ignores subagent files")
  func claudeTargetedRestoreIgnoresSubagents() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let projectPath = "/tmp/project"
    let sessionId = "11111111-1111-1111-1111-111111111111"
    let projectDir = root
      .appending(path: "projects")
      .appending(path: projectPath.claudeProjectPathEncoded)
    let subagentDir = projectDir.appending(path: "subagents")
    try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

    let mainFile = projectDir.appending(path: "\(sessionId).jsonl")
    let subagentFile = subagentDir.appending(path: "\(sessionId).jsonl")
    try claudeLine(
      sessionId: sessionId,
      cwd: projectPath,
      message: "main session",
      timestamp: "2026-05-05T12:00:00.000Z"
    ).write(to: mainFile, atomically: true, encoding: .utf8)
    try claudeLine(
      sessionId: sessionId,
      cwd: "/tmp/subagent",
      message: "subagent session",
      timestamp: "2026-05-05T12:01:00.000Z"
    ).write(to: subagentFile, atomically: true, encoding: .utf8)

    let service = CLISessionMonitorService(claudeDataPath: root.path)
    let sessions = await service.loadSessions(ids: [sessionId])

    #expect(sessions.count == 1)
    #expect(sessions.first?.projectPath == projectPath)
    #expect(sessions.first?.firstMessage == "main session")
    let sessionFilePath = try #require(sessions.first?.sessionFilePath)
    #expect(
      URL(fileURLWithPath: sessionFilePath).resolvingSymlinksInPath().path
        == mainFile.resolvingSymlinksInPath().path
    )
  }

  @Test("Codex targeted restore returns only requested sessions")
  func codexTargetedRestoreReturnsOnlyRequestedSessions() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionsDir = root
      .appending(path: "sessions")
      .appending(path: "2026")
      .appending(path: "05")
      .appending(path: "05")
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let requestedId = "22222222-2222-2222-2222-222222222222"
    let otherId = "33333333-3333-3333-3333-333333333333"
    let guardianId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    try codexLines(
      sessionId: requestedId,
      cwd: "/tmp/project",
      message: "requested",
      baseInstructionsLength: 24_000
    )
      .write(
        to: sessionsDir.appending(path: "rollout-2026-05-05T12-00-00-\(requestedId).jsonl"),
        atomically: true,
        encoding: .utf8
      )
    try codexLines(sessionId: otherId, cwd: "/tmp/other", message: "other")
      .write(
        to: sessionsDir.appending(path: "rollout-2026-05-05T12-01-00-\(otherId).jsonl"),
        atomically: true,
        encoding: .utf8
      )
    try codexLines(
      sessionId: guardianId,
      cwd: "/tmp/project",
      message: "internal guardian",
      source: ["subagent": ["other": "guardian"]]
    )
      .write(
        to: sessionsDir.appending(path: "rollout-2026-05-05T12-02-00-\(guardianId).jsonl"),
        atomically: true,
        encoding: .utf8
      )

    let service = CodexSessionMonitorService(codexDataPath: root.path)
    let sessions = await service.loadSessions(ids: [requestedId, guardianId])

    #expect(sessions.map(\.id) == [requestedId])
    #expect(sessions.first?.firstMessage == "requested")
    #expect(sessions.first?.projectPath == "/tmp/project")
  }

  @Test("Codex pending session resolves from configured data path with oversized session metadata")
  func codexPendingSessionResolvesFromConfiguredDataPath() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let projectURL = root.appending(path: "project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

    let watcher = RecordingFileWatcher()
    let processInspector = MutableCodexProcessOpenFileInspector()
    let monitorService = CodexSessionMonitorService(codexDataPath: root.path)
    let viewModel = CLISessionsViewModel(
      monitorService: monitorService,
      fileWatcher: watcher,
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
      providerKind: .codex,
      approvalNotificationService: NoOpApprovalNotificationService(),
      codexDataPath: root.path,
      codexPendingSessionProcessResolver: CodexPendingSessionProcessResolver(
        openFileInspector: processInspector
      )
    )

    viewModel.addRepository(at: projectURL.path)

    await waitUntil(timeout: .seconds(6)) {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }

    let worktree = try #require(
      viewModel.selectedRepositories.first?.worktrees.first(where: { $0.path == projectURL.path })
    )

    viewModel.startNewSessionInHub(worktree, initialPrompt: "pending codex")

    await waitUntil {
      viewModel.pendingHubSessions.count == 1
    }

    let pending = try #require(viewModel.pendingHubSessions.first)
    let pendingKey = "pending-\(pending.id.uuidString)"
    let terminal = TestTerminalSurface()
    terminal.currentProcessPID = 404
    viewModel.activeTerminals[pendingKey] = terminal
    let sessionId = "44444444-4444-4444-4444-444444444444"
    let sessionsDir = root
      .appending(path: "sessions")
      .appending(path: "2026")
      .appending(path: "05")
      .appending(path: "05")
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let sessionFile = sessionsDir.appending(
      path: "rollout-2026-05-05T12-02-00-\(sessionId).jsonl"
    )
    await processInspector.setOpenFilePaths(
      [sessionFile.path, sessionFile.resolvingSymlinksInPath().path],
      for: 404
    )

    try codexLines(
      sessionId: sessionId,
      cwd: projectURL.path,
      message: "pending codex",
      baseInstructionsLength: 24_000,
      timestamp: ISO8601DateFormatter().string(from: Date())
    )
    .write(
      to: sessionFile,
      atomically: true,
      encoding: .utf8
    )

    await waitUntil(timeout: .seconds(8)) {
      viewModel.resolvedPendingSessions[pending.id] == sessionId
        && !viewModel.pendingHubSessions.contains(where: { $0.id == pending.id })
        && viewModel.monitoredSessions.contains(where: { $0.session.id == sessionId })
    }

    #expect(viewModel.findSession(byId: sessionId)?.projectPath == projectURL.path)
    // The watcher starts asynchronously after the session lands in
    // monitoredSessions, so poll instead of asserting immediately.
    await waitUntilAsync {
      (await watcher.startedSessionIds()).contains(sessionId)
    }
  }

  @Test("Codex pending session ignores an older active rollout with a recent file write")
  func codexPendingSessionIgnoresOlderActiveRollout() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let projectURL = root.appending(path: "project", directoryHint: .isDirectory)
    let sessionsDir = root
      .appending(path: "sessions")
      .appending(path: "2026")
      .appending(path: "09")
      .appending(path: "02")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let oldSessionId = "55555555-5555-5555-5555-555555555555"
    try codexLines(
      sessionId: oldSessionId,
      cwd: projectURL.path,
      message: "older active session",
      timestamp: "2026-09-01T06:00:00.000Z"
    ).write(
      to: sessionsDir.appending(path: "rollout-old-\(oldSessionId).jsonl"),
      atomically: true,
      encoding: .utf8
    )

    let viewModel = makeCodexPendingViewModel(root: root)
    viewModel.addRepository(at: projectURL.path)
    await waitUntil(timeout: .seconds(6)) {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    let worktree = try #require(
      viewModel.selectedRepositories.first?.worktrees.first(where: { $0.path == projectURL.path })
    )

    viewModel.startNewSessionInHub(worktree, initialPrompt: "new independent work")
    await waitUntil { viewModel.pendingHubSessions.count == 1 }
    let pending = try #require(viewModel.pendingHubSessions.first)

    try? await Task.sleep(for: .milliseconds(1_200))
    #expect(viewModel.resolvedPendingSessions[pending.id] == nil)
    #expect(viewModel.pendingHubSessions.contains(where: { $0.id == pending.id }))

    let newSessionId = "66666666-6666-6666-6666-666666666666"
    try codexLines(
      sessionId: newSessionId,
      cwd: projectURL.path,
      message: "new independent work",
      timestamp: ISO8601DateFormatter().string(from: Date())
    ).write(
      to: sessionsDir.appending(path: "rollout-new-\(newSessionId).jsonl"),
      atomically: true,
      encoding: .utf8
    )

    await waitUntil(timeout: .seconds(8)) {
      viewModel.resolvedPendingSessions[pending.id] == newSessionId
    }
  }

  @Test("Codex pending session resolves its owned rollout while history refresh is stale")
  func codexPendingSessionResolvesOwnedRolloutWithStaleHistory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let projectURL = root.appending(path: "project", directoryHint: .isDirectory)
    let sessionsDir = root
      .appending(path: "sessions")
      .appending(path: "2026")
      .appending(path: "09")
      .appending(path: "02")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let existingSession = CLISession(
      id: "55555555-5555-5555-5555-555555555555",
      projectPath: projectURL.path,
      branchName: "main"
    )
    let staleRepository = repository(path: projectURL.path, sessions: [existingSession])
    let monitorService = LazyBrowseMockMonitorService(
      skeletonRepositories: [staleRepository],
      browseRepositories: [staleRepository]
    )
    let processInspector = MutableCodexProcessOpenFileInspector()
    let viewModel = makeCodexPendingViewModel(
      root: root,
      openFileInspector: processInspector,
      monitorService: monitorService
    )
    viewModel.addRepository(at: projectURL.path)
    await waitUntil(timeout: .seconds(6)) {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    let worktree = try #require(
      viewModel.selectedRepositories.first?.worktrees.first(where: { $0.path == projectURL.path })
    )

    viewModel.startNewSessionInHub(worktree, initialPrompt: "owned rollout")
    await waitUntil { viewModel.pendingHubSessions.count == 1 }
    let pending = try #require(viewModel.pendingHubSessions.first)
    let pendingKey = "pending-\(pending.id.uuidString)"
    let terminal = TestTerminalSurface()
    terminal.currentProcessPID = 303
    viewModel.activeTerminals[pendingKey] = terminal
    try? await Task.sleep(for: .milliseconds(250))

    let newSessionId = "66666666-6666-6666-6666-666666666666"
    let newSessionFile = sessionsDir.appending(path: "rollout-owned-\(newSessionId).jsonl")
    await processInspector.setOpenFilePaths([newSessionFile.path], for: 303)
    try codexLines(
      sessionId: newSessionId,
      cwd: projectURL.path,
      message: "owned rollout",
      timestamp: ISO8601DateFormatter().string(from: Date())
    ).write(to: newSessionFile, atomically: true, encoding: .utf8)

    await waitUntil(timeout: .seconds(8)) {
      viewModel.resolvedPendingSessions[pending.id] == newSessionId
    }
    #expect(viewModel.pendingHubSessions.allSatisfy { $0.id != pending.id })
    let resolvedSessionFilePath = try #require(
      viewModel.findSession(byId: newSessionId)?.sessionFilePath
    )
    #expect(
      URL(fileURLWithPath: resolvedSessionFilePath).resolvingSymlinksInPath().path
        == newSessionFile.resolvingSymlinksInPath().path
    )
  }

  @Test("Two Codex pending sessions claim distinct rollout identities")
  func concurrentCodexPendingSessionsClaimDistinctRollouts() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let projectURL = root.appending(path: "project", directoryHint: .isDirectory)
    let sessionsDir = root
      .appending(path: "sessions")
      .appending(path: "2026")
      .appending(path: "09")
      .appending(path: "02")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let processInspector = MutableCodexProcessOpenFileInspector()
    let viewModel = makeCodexPendingViewModel(root: root, openFileInspector: processInspector)
    viewModel.addRepository(at: projectURL.path)
    await waitUntil(timeout: .seconds(6)) {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    let worktree = try #require(
      viewModel.selectedRepositories.first?.worktrees.first(where: { $0.path == projectURL.path })
    )

    viewModel.startNewSessionInHub(worktree, initialPrompt: "first")
    viewModel.startNewSessionInHub(worktree, initialPrompt: "second")
    await waitUntil { viewModel.pendingHubSessions.count == 2 }
    let pendingIds = viewModel.pendingHubSessions.map(\.id)
    let firstPendingKey = "pending-\(pendingIds[0].uuidString)"
    let secondPendingKey = "pending-\(pendingIds[1].uuidString)"
    let firstTerminal = TestTerminalSurface()
    firstTerminal.currentProcessPID = 101
    let secondTerminal = TestTerminalSurface()
    secondTerminal.currentProcessPID = 202
    viewModel.activeTerminals[firstPendingKey] = firstTerminal
    viewModel.activeTerminals[secondPendingKey] = secondTerminal
    try? await Task.sleep(for: .milliseconds(250))

    let firstSessionId = "77777777-7777-7777-7777-777777777777"
    let firstSessionFile = sessionsDir.appending(path: "rollout-first-\(firstSessionId).jsonl")
    await processInspector.setOpenFilePaths([firstSessionFile.path], for: 101)
    try codexLines(
      sessionId: firstSessionId,
      cwd: projectURL.path,
      message: "first",
      timestamp: ISO8601DateFormatter().string(from: Date())
    ).write(
      to: firstSessionFile,
      atomically: true,
      encoding: .utf8
    )

    await waitUntil(timeout: .seconds(8)) {
      pendingIds.filter { viewModel.resolvedPendingSessions[$0] != nil }.count == 1
    }
    #expect(viewModel.resolvedPendingSessions[pendingIds[0]] == firstSessionId)
    #expect(viewModel.resolvedPendingSessions[pendingIds[1]] == nil)

    let secondSessionId = "88888888-8888-8888-8888-888888888888"
    let secondSessionFile = sessionsDir.appending(path: "rollout-second-\(secondSessionId).jsonl")
    await processInspector.setOpenFilePaths([secondSessionFile.path], for: 202)
    try codexLines(
      sessionId: secondSessionId,
      cwd: projectURL.path,
      message: "second",
      timestamp: ISO8601DateFormatter().string(from: Date())
    ).write(
      to: secondSessionFile,
      atomically: true,
      encoding: .utf8
    )

    await waitUntil(timeout: .seconds(8)) {
      pendingIds.allSatisfy { viewModel.resolvedPendingSessions[$0] != nil }
    }
    #expect(viewModel.resolvedPendingSessions[pendingIds[0]] == firstSessionId)
    #expect(viewModel.resolvedPendingSessions[pendingIds[1]] == secondSessionId)
  }

  @Test("Codex pending session ignores an internal guardian rollout")
  func codexPendingSessionIgnoresGuardianRollout() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let projectURL = root.appending(path: "project", directoryHint: .isDirectory)
    let sessionsDir = root
      .appending(path: "sessions")
      .appending(path: "2026")
      .appending(path: "09")
      .appending(path: "02")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let viewModel = makeCodexPendingViewModel(root: root)
    viewModel.addRepository(at: projectURL.path)
    await waitUntil(timeout: .seconds(6)) {
      viewModel.loadingState == .idle && viewModel.selectedRepositories.count == 1
    }
    let worktree = try #require(
      viewModel.selectedRepositories.first?.worktrees.first(where: { $0.path == projectURL.path })
    )

    viewModel.startNewSessionInHub(worktree, initialPrompt: "root request")
    await waitUntil { viewModel.pendingHubSessions.count == 1 }
    let pending = try #require(viewModel.pendingHubSessions.first)

    let guardianSessionId = "99999999-9999-9999-9999-999999999999"
    try codexLines(
      sessionId: guardianSessionId,
      cwd: projectURL.path,
      message: "internal guardian",
      timestamp: ISO8601DateFormatter().string(from: Date()),
      source: ["subagent": ["other": "guardian"]]
    ).write(
      to: sessionsDir.appending(path: "rollout-guardian-\(guardianSessionId).jsonl"),
      atomically: true,
      encoding: .utf8
    )

    try? await Task.sleep(for: .milliseconds(1_200))
    #expect(viewModel.resolvedPendingSessions[pending.id] == nil)
    #expect(viewModel.pendingHubSessions.contains(where: { $0.id == pending.id }))

    let rootSessionId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    try codexLines(
      sessionId: rootSessionId,
      cwd: projectURL.path,
      message: "root request",
      timestamp: ISO8601DateFormatter().string(from: Date())
    ).write(
      to: sessionsDir.appending(path: "rollout-root-\(rootSessionId).jsonl"),
      atomically: true,
      encoding: .utf8
    )

    await waitUntil(timeout: .seconds(8)) {
      viewModel.resolvedPendingSessions[pending.id] == rootSessionId
    }
    #expect(viewModel.findSession(byId: guardianSessionId) == nil)
  }
}

private actor LazyBrowseMockMonitorService: SessionMonitorServiceProtocol {
  nonisolated(unsafe) private let subject = CurrentValueSubject<[SelectedRepository], Never>([])

  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  private var repositories: [SelectedRepository] = []
  private let skeletonRepositories: [SelectedRepository]
  private let browseRepositories: [SelectedRepository]
  private let sessionsById: [String: CLISession]
  private let restoreSkeletonDelay: Duration?
  private var restoreSkeletonCount = 0
  private var addRepositoriesCount = 0
  private var refreshCount = 0
  private var loadSessionRequests: [Set<String>] = []

  init(
    skeletonRepositories: [SelectedRepository],
    browseRepositories: [SelectedRepository],
    sessionsById: [String: CLISession] = [:],
    restoreSkeletonDelay: Duration? = nil
  ) {
    self.skeletonRepositories = skeletonRepositories
    self.browseRepositories = browseRepositories
    self.sessionsById = sessionsById
    self.restoreSkeletonDelay = restoreSkeletonDelay
  }

  func addRepository(_ path: String) async -> SelectedRepository? {
    addRepositoriesCount += 1
    guard !repositories.contains(where: { $0.path == path }) else {
      return nil
    }

    let repositoryToAdd = browseRepositories.first { $0.path == path }
      ?? skeletonRepositories.first { $0.path == path }
      ?? repository(path: path)
    repositories.append(repositoryToAdd)
    subject.send(repositories)
    return repositoryToAdd
  }

  func addRepositories(_ paths: [String]) async {
    addRepositoriesCount += 1
  }

  func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] {
    if let restoreSkeletonDelay {
      try? await Task.sleep(for: restoreSkeletonDelay)
    }
    restoreSkeletonCount += 1
    repositories = skeletonRepositories
    subject.send(repositories)
    return repositories
  }

  func loadSessions(ids: Set<String>) async -> [CLISession] {
    loadSessionRequests.append(ids)
    return ids.compactMap { sessionsById[$0] }
  }

  func removeRepository(_ path: String) async {}

  func getSelectedRepositories() async -> [SelectedRepository] {
    repositories
  }

  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    self.repositories = repositories
    subject.send(repositories)
  }

  func refreshSessions(skipWorktreeRedetection: Bool) async {
    refreshCount += 1
    repositories = browseRepositories
    subject.send(repositories)
  }

  func calls() -> LazyBrowseMockCalls {
    LazyBrowseMockCalls(
      restoreSkeletonCount: restoreSkeletonCount,
      addRepositoriesCount: addRepositoriesCount,
      refreshCount: refreshCount,
      loadSessionRequests: loadSessionRequests
    )
  }
}

private struct LazyBrowseMockCalls: Sendable {
  let restoreSkeletonCount: Int
  let addRepositoriesCount: Int
  let refreshCount: Int
  let loadSessionRequests: [Set<String>]
}

private actor RecordingFileWatcher: SessionFileWatcherProtocol {
  nonisolated(unsafe) private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  private var started: [String] = []
  private var stopped: [String] = []

  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {
    started.append(sessionId)
  }

  func stopMonitoring(sessionId: String) async {
    stopped.append(sessionId)
  }
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}

  func startedSessionIds() -> [String] {
    started
  }

  func stoppedSessionIds() -> [String] {
    stopped
  }
}

private actor RecordingClaudeHookInstaller: ClaudeHookInstallerProtocol {
  private var requests: [Set<String>] = []
  private var enabled = true

  func isEnabled() async -> Bool {
    enabled
  }

  func setEnabled(_ enabled: Bool) async {
    self.enabled = enabled
  }

  func syncInstalledPaths(_ paths: Set<String>) async {
    requests.append(paths)
  }

  func flushAll() async {}

  func reconcileOnLaunch(expectedPaths: [String]) async {}

  func syncRequests() -> [Set<String>] {
    requests
  }
}

private func repository(path: String, sessions: [CLISession] = []) -> SelectedRepository {
  SelectedRepository(
    path: path,
    worktrees: [
      WorktreeBranch(name: "main", path: path, isWorktree: false, sessions: sessions)
    ]
  )
}

private func repositoryWithWorktree(path: String, worktreePath: String) -> SelectedRepository {
  SelectedRepository(
    path: path,
    worktrees: [
      WorktreeBranch(name: "main", path: path, isWorktree: false),
      WorktreeBranch(name: "feature", path: worktreePath, isWorktree: true),
    ]
  )
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(2),
  condition: @escaping @MainActor () -> Bool
) async {
  let start = ContinuousClock.now
  while !condition(), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

private func waitUntilAsync(
  timeout: Duration = .seconds(2),
  condition: @escaping () async -> Bool
) async {
  let start = ContinuousClock.now
  while !(await condition()), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(await condition())
}

private func temporaryDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "lazy_browse_\(UUID().uuidString).sqlite")
    .path
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "lazy_browse_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func claudeLine(
  sessionId: String,
  cwd: String,
  message: String,
  timestamp: String
) -> String {
  """
  {"sessionId":"\(sessionId)","cwd":"\(cwd)","gitBranch":"main","slug":"test-slug","type":"user","timestamp":"\(timestamp)","message":{"role":"user","content":"\(message)"}}

  """
}

private func codexLines(
  sessionId: String,
  cwd: String,
  message: String,
  baseInstructionsLength: Int = 0,
  timestamp: String = "2026-05-05T12:00:00.000Z",
  source: Any = "cli"
) -> String {
  var sessionMetaPayload: [String: Any] = [
    "id": sessionId,
    "timestamp": timestamp,
    "cwd": cwd,
    "source": source,
    "git": [
      "branch": "main"
    ]
  ]

  if baseInstructionsLength > 0 {
    sessionMetaPayload["base_instructions"] = [
      "text": String(repeating: "x", count: baseInstructionsLength)
    ]
  }

  let sessionMeta: [String: Any] = [
    "timestamp": timestamp,
    "type": "session_meta",
    "payload": sessionMetaPayload
  ]
  let userMessage: [String: Any] = [
    "timestamp": "2026-05-05T12:00:01.000Z",
    "type": "event_msg",
    "payload": [
      "type": "user_message",
      "message": message
    ]
  ]

  return """
  \(jsonLine(sessionMeta))
  \(jsonLine(userMessage))

  """
}

@MainActor
private func makeCodexPendingViewModel(
  root: URL,
  openFileInspector: any CodexProcessOpenFileInspecting = DarwinCodexProcessOpenFileInspector(),
  monitorService: (any SessionMonitorServiceProtocol)? = nil
) -> CLISessionsViewModel {
  let resolvedMonitorService: any SessionMonitorServiceProtocol
  if let monitorService {
    resolvedMonitorService = monitorService
  } else {
    resolvedMonitorService = CodexSessionMonitorService(codexDataPath: root.path)
  }

  return CLISessionsViewModel(
    monitorService: resolvedMonitorService,
    fileWatcher: RecordingFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex),
    providerKind: .codex,
    approvalNotificationService: NoOpApprovalNotificationService(),
    codexDataPath: root.path,
    codexPendingSessionProcessResolver: CodexPendingSessionProcessResolver(
      openFileInspector: openFileInspector
    )
  )
}

private actor MutableCodexProcessOpenFileInspector: CodexProcessOpenFileInspecting {
  private var pathsByProcessId: [Int32: Set<String>] = [:]

  func setOpenFilePaths(_ paths: Set<String>, for processId: Int32) {
    pathsByProcessId[processId] = paths
  }

  func openFilePaths(for processId: Int32) async -> Set<String> {
    pathsByProcessId[processId] ?? []
  }
}

private func jsonLine(_ object: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: object)
  return String(decoding: data, as: UTF8.self)
}
