//
//  CodexPendingSessionCandidateResolver.swift
//  AgentHubSessionGraph
//
//  Resolves a pending Codex launch without confusing recent writes to an
//  existing rollout with creation of a new session.
//

import Foundation

public enum CodexPendingSessionCandidateResolver {
  public static func selectCandidate(
    in filePaths: Set<String>,
    matchingProjectRoots: [String],
    pendingStartedAt: Date,
    requiresIntrinsicStartAfterPending: Bool,
    claimedSessionIds: Set<String> = [],
    ownedSessionFilePaths: Set<String>? = nil,
    requiresProcessOwnership: Bool = false,
    fileManager: FileManager = .default
  ) -> CodexSessionMeta? {
    guard !filePaths.isEmpty, !matchingProjectRoots.isEmpty else { return nil }
    if requiresProcessOwnership, ownedSessionFilePaths == nil {
      return nil
    }

    let cutoff = pendingStartedAt.addingTimeInterval(-2)
    let normalizedOwnedPaths = ownedSessionFilePaths.map {
      Set($0.map(normalizedPath))
    }
    var newest: (meta: CodexSessionMeta, activityAt: Date)?

    for path in filePaths {
      guard let meta = CodexSessionFileScanner.readSessionMeta(from: path) else { continue }
      guard meta.isFreshInteractiveRoot else { continue }
      if let normalizedOwnedPaths,
         !normalizedOwnedPaths.contains(normalizedPath(path)) {
        continue
      }
      guard !claimedSessionIds.contains(meta.sessionId) else { continue }
      guard matchesProject(meta.projectPath, roots: matchingProjectRoots) else { continue }

      if requiresIntrinsicStartAfterPending {
        guard let startedAt = meta.startedAt, startedAt >= cutoff else { continue }
      }

      let activityAt = meta.startedAt ?? fileActivityDate(path, fileManager: fileManager)
      guard let activityAt else { continue }

      if let current = newest {
        if activityAt > current.activityAt
          || (activityAt == current.activityAt && meta.sessionFilePath < current.meta.sessionFilePath) {
          newest = (meta, activityAt)
        }
      } else {
        newest = (meta, activityAt)
      }
    }

    return newest?.meta
  }

  private static func matchesProject(_ projectPath: String, roots: [String]) -> Bool {
    roots.contains { root in
      projectPath == root || projectPath.hasPrefix(root + "/")
    }
  }

  private static func fileActivityDate(_ path: String, fileManager: FileManager) -> Date? {
    guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }
    return (attrs[.modificationDate] as? Date) ?? (attrs[.creationDate] as? Date)
  }

  private static func normalizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
