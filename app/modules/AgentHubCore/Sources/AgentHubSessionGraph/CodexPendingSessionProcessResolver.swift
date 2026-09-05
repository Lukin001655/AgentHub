//
//  CodexPendingSessionProcessResolver.swift
//  AgentHubSessionGraph
//
//  Uses the pending terminal process as provenance for concurrent Codex launches.
//

import Darwin
import Foundation

public protocol CodexProcessOpenFileInspecting: Sendable {
  func openFilePaths(for processId: Int32) async -> Set<String>
}

public struct DarwinCodexProcessOpenFileInspector: CodexProcessOpenFileInspecting {
  public init() {}

  public func openFilePaths(for processId: Int32) async -> Set<String> {
    guard processId > 0 else { return [] }

    let descriptorSize = MemoryLayout<proc_fdinfo>.stride
    let requiredBytes = proc_pidinfo(processId, PROC_PIDLISTFDS, 0, nil, 0)
    guard requiredBytes > 0, descriptorSize > 0 else { return [] }

    let descriptorCapacity = max(Int(requiredBytes) / descriptorSize + 32, 32)
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: descriptorCapacity)
    let bufferBytes = descriptors.count * descriptorSize
    let filledBytes = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(
        processId,
        PROC_PIDLISTFDS,
        0,
        buffer.baseAddress,
        Int32(bufferBytes)
      )
    }
    guard filledBytes > 0 else { return [] }

    let descriptorCount = min(Int(filledBytes) / descriptorSize, descriptors.count)
    var paths: Set<String> = []

    for descriptor in descriptors.prefix(descriptorCount) {
      guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
      var vnodeInfo = vnode_fdinfowithpath()
      let infoBytes = withUnsafeMutableBytes(of: &vnodeInfo) { buffer in
        proc_pidfdinfo(
          processId,
          descriptor.proc_fd,
          PROC_PIDFDVNODEPATHINFO,
          buffer.baseAddress,
          Int32(buffer.count)
        )
      }
      guard infoBytes == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }

      let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
          String(cString: $0)
        }
      }
      guard !path.isEmpty else { continue }
      paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    return paths
  }
}

public struct CodexPendingSessionProcessResolver: Sendable {
  private let openFileInspector: any CodexProcessOpenFileInspecting

  public init(
    openFileInspector: any CodexProcessOpenFileInspecting = DarwinCodexProcessOpenFileInspector()
  ) {
    self.openFileInspector = openFileInspector
  }

  public func selectCandidate(
    in filePaths: Set<String>,
    matchingProjectRoots: [String],
    pendingStartedAt: Date,
    requiresIntrinsicStartAfterPending: Bool,
    claimedSessionIds: Set<String>,
    owningProcessId: Int32?,
    requiresProcessOwnership: Bool,
    fileManager: FileManager = .default
  ) async -> CodexSessionMeta? {
    let ownedSessionFilePaths: Set<String>?
    if requiresProcessOwnership {
      guard let owningProcessId, owningProcessId > 0 else { return nil }
      ownedSessionFilePaths = await openFileInspector.openFilePaths(for: owningProcessId)
    } else {
      ownedSessionFilePaths = nil
    }

    return CodexPendingSessionCandidateResolver.selectCandidate(
      in: filePaths,
      matchingProjectRoots: matchingProjectRoots,
      pendingStartedAt: pendingStartedAt,
      requiresIntrinsicStartAfterPending: requiresIntrinsicStartAfterPending,
      claimedSessionIds: claimedSessionIds,
      ownedSessionFilePaths: ownedSessionFilePaths,
      requiresProcessOwnership: requiresProcessOwnership,
      fileManager: fileManager
    )
  }
}
