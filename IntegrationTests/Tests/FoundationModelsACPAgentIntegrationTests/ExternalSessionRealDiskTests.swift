import Darwin
import Foundation
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

/// The index of the external sessions on the real disk (D212, section 7): a Claude Code root of
/// 5,000 generated session files in a temporary folder. The first row of a folder comes in less
/// than 1 s, and the build of the index adds less than 100 MB to the memory of the process.
///
/// The memory is the physical footprint of the process, read at each change that the build sends
/// and at its end. The test does not read the peak of the process: the other suites of the
/// process (real models) set that peak before this test runs.
///
/// The unit suites test the index on a fake file system. This suite reads real files, through
/// the public host of the agent (``RoutedACPAgent/externalSessionHost``).
@Suite struct ExternalSessionRealDiskTests {
  /// The number of session files.
  private static let fileCount = 5_000

  /// The number of project folders.
  private static let projectCount = 50

  /// Each file whose number has the remainder 0 by this value is large (``largeFileSize``).
  private static let largeFileCycle = 100

  /// The approximate size of a large file: 1 MB.
  private static let largeFileSize = 1_048_576

  /// Of each 100 files, the number that are automated (`sdk-cli`). The others are typed.
  private static let automatedShare = 93

  /// The time limit of the first row of a folder (section 7).
  private static let firstRowLimit = Duration.seconds(1)

  /// The limit of the increase of the memory (section 7): 100 MB.
  private static let memoryLimit: UInt64 = 100 * 1_048_576

  @Test("the first row of a folder comes in less than 1 s, and the build adds less than 100 MB")
  func theRealDiskIndexIsFastAndSmall() async throws {
    let base = TestRunFolder.temporary.appendingPathComponent(
      "ExternalSessionRealDiskTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent(".claude", isDirectory: true)
    try Self.writeStore(in: root)
    let agent = try await AgentClientHarness.makeAgent()
    let host = agent.externalSessionHost
    let folder = Self.folder(of: 0)

    let memoryBefore = Self.footprint()
    var memoryHigh = memoryBefore
    var folderChanges = host.externalSessionChanges(folder: folder).makeAsyncIterator()
    var allChanges = host.externalSessionChanges(folder: nil).makeAsyncIterator()
    _ = await folderChanges.next()
    _ = await allChanges.next()
    let clock = ContinuousClock()
    let start = clock.now
    await agent.setImportRoots([.claudeCode: root])
    var firstRow: ExternalSessionSummary?
    while firstRow == nil, let change = await folderChanges.next() {
      memoryHigh = max(memoryHigh, Self.footprint())
      firstRow = change.changed.first
    }
    let firstRowTime = clock.now - start
    var isComplete = false
    while !isComplete, let change = await allChanges.next() {
      memoryHigh = max(memoryHigh, Self.footprint())
      isComplete = change.indexState.isComplete
    }
    let buildTime = clock.now - start
    memoryHigh = max(memoryHigh, Self.footprint())
    let page = try await host.externalSessions(
      ExternalSessionQuery(automated: true, limit: Self.fileCount))
    let increase = memoryHigh - memoryBefore

    print(
      "ExternalSessionRealDiskTests: first row \(firstRowTime), build \(buildTime), "
        + "memory increase \(increase / 1_048_576) MB")
    #expect(firstRow?.cwd?.standardizedFileURL.path == folder.path)
    #expect(page.sessions.count == Self.fileCount)
    #expect(firstRowTime < Self.firstRowLimit)
    #expect(increase < Self.memoryLimit)
  }

  // MARK: - The store

  /// The working folder of a project.
  ///
  /// - Parameter project: The number of the project.
  /// - Returns: The folder.
  private static func folder(of project: Int) -> URL {
    URL(fileURLWithPath: "/work/project-\(project)", isDirectory: true)
  }

  /// Writes the Claude Code store: file `n` is in project `n % projectCount`.
  ///
  /// - Parameter root: The Claude Code root.
  /// - Throws: The error of a write.
  private static func writeStore(in root: URL) throws {
    for number in 0..<fileCount {
      let folder = folder(of: number % projectCount)
      let project = folder.path.replacingOccurrences(of: "/", with: "-")
      let directory = root.appendingPathComponent("projects/\(project)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let id = UUID().uuidString.lowercased()
      try sessionFile(id: id, number: number, folder: folder)
        .write(to: directory.appendingPathComponent("\(id).jsonl"))
    }
  }

  /// The bytes of one session file: a user record, the records of an answer, and, for a large
  /// file, more answer records until the file is about ``largeFileSize``.
  ///
  /// - Parameters:
  ///   - id: The id of the session.
  ///   - number: The number of the file.
  ///   - folder: The working folder of the session.
  /// - Returns: The bytes.
  private static func sessionFile(id: String, number: Int, folder: URL) -> Data {
    let entrypoint = number % 100 < automatedShare ? "sdk-cli" : "cli"
    let minute = String(format: "%02d", number % 60)
    let user = """
      {"type":"user","uuid":"u-\(number)","sessionId":"\(id)","timestamp":"2026-11-01T10:\(minute):01.000Z","cwd":"\(folder.path)","entrypoint":"\(entrypoint)","message":{"role":"user","content":"Fix test \(number)."}}
      """
    let answer = """
      {"type":"assistant","uuid":"a-\(number)","sessionId":"\(id)","timestamp":"2026-11-01T10:\(minute):04.000Z","cwd":"\(folder.path)","message":{"role":"assistant","content":[{"type":"text","text":"Test \(number) passes now."}]}}
      """
    var lines = [user, answer]
    if number % largeFileCycle == 0 {
      let count = largeFileSize / answer.utf8.count
      lines += Array(repeating: answer, count: count)
    }
    return Data((lines + [""]).joined(separator: "\n").utf8)
  }

  // MARK: - The memory

  /// The physical footprint of the process now.
  ///
  /// - Returns: The footprint, in bytes, or 0 when the read fails.
  private static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.phys_footprint
  }
}
