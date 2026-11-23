import Foundation
import FoundationModelsACP
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The walk of ``RecordedSessionFolder/unlistedRecordIds(under:listed:)``.
@Suite struct RecordedSessionFolderTests {
  /// A dotfile does not hide a session folder. Each session folder holds a dotfile and a child
  /// session folder, because the walk order of the file system is not fixed: a walk that skips
  /// the rest of a folder at a dotfile loses at least one child. A dot folder is still not
  /// searched.
  @Test func aDotfileDoesNotHideASessionFolder() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecordedSessionFolderTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".gitattributes"))
    let dotFolder = root.appendingPathComponent(".\(ULID.generate().description).writing", isDirectory: true)
    try FileManager.default.createDirectory(at: dotFolder, withIntermediateDirectories: true)
    try Data().write(to: dotFolder.appendingPathComponent("index.md"))
    var expected: Set<SessionId> = []
    for _ in 0..<20 {
      let session = root.appendingPathComponent(ULID.generate().description, isDirectory: true)
      let child = session.appendingPathComponent(ULID.generate().description, isDirectory: true)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      try Data().write(to: session.appendingPathComponent(".gitattributes"))
      for folder in [session, child] {
        try Data().write(to: folder.appendingPathComponent("index.md"))
        expected.insert(SessionId(rawValue: folder.lastPathComponent))
      }
    }

    let ids = RecordedSessionFolder.unlistedRecordIds(under: root, listed: [])

    #expect(ids == expected)
  }
}
