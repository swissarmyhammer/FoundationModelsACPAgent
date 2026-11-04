import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The reader that gives a tool the recorded events of a session
/// (``RecordedSessionTranscriptReader``): the order and the content of the
/// entries, the unknown id, the cache of the session folders, and the
/// events that a running session has on disk.
///
/// Every recorded session is a real session, driven through
/// ``makeRecordedProjectFixture(workingDirectory:cacheDirectory:recordingRoot:)``.
/// The mapping test writes the lines of a `transcript.jsonl` by hand,
/// because `TranscriptEvent` has no public init.
@Suite struct RecordedSessionTranscriptReaderTests {
  /// The prompt texts of the recorded session.
  private static let prompts = ["first prompt", "second prompt"]

  /// One recorded project and the reader over its recording root.
  private struct ReaderFixture {
    /// The directories of the fixture, removed by ``cleanUp()``.
    let directories: [URL]

    /// The recorded project.
    let recorded: RecordedProjectFixture

    /// The count of the roots resolutions that the reader made.
    let resolutions: CallCounter

    /// The reader under test.
    let reader: RecordedSessionTranscriptReader

    /// Removes every directory of the fixture.
    func cleanUp() {
      for directory in directories {
        try? FileManager.default.removeItem(at: directory)
      }
    }
  }

  /// Makes a project fixture and a reader over its recording root.
  ///
  /// - Returns: The fixture. The caller cleans it up.
  /// - Throws: Whatever the directory creation or the profile throws.
  private static func makeFixture() async throws -> ReaderFixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RecordedSessionTranscriptReaderTests-\(UUID().uuidString)", isDirectory: true)
    let project = base.appendingPathComponent("project", isDirectory: true)
    let cache = base.appendingPathComponent("cache", isDirectory: true)
    let root = base.appendingPathComponent("recordings", isDirectory: true)
    for directory in [project, cache, root] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let resolutions = CallCounter()
    return ReaderFixture(
      directories: [base],
      recorded: try await makeRecordedProjectFixture(
        workingDirectory: project, cacheDirectory: cache, recordingRoot: root),
      resolutions: resolutions,
      reader: RecordedSessionTranscriptReader {
        resolutions.record()
        return [root]
      })
  }

  /// The text at `key` in the payload of an entry, or `nil` when the
  /// payload has no text there.
  private static func payloadText(_ key: String, of entry: SessionTranscriptEntry) -> String? {
    if case .object(let fields) = entry.payload, case .string(let text)? = fields[key] {
      return text
    }
    return nil
  }

  // MARK: - The entries

  @Test("the entries of a recorded session keep the kinds of its events, in order")
  func entriesKeepTheKindsInOrder() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = try await fixture.recorded.makeRecordedSession(prompts: Self.prompts)

    let transcript = try await fixture.reader.transcript(of: id)
    let events = try TranscriptEvent.read(
      sessionDirectory: fixture.recorded.root.appendingPathComponent(
        id.description, isDirectory: true))

    #expect(transcript.entries.map(\.kind) == events.map(\.kind.rawValue))
  }

  @Test("the transcript names the session that was read")
  func transcriptNamesTheSession() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = try await fixture.recorded.makeRecordedSession(prompts: Self.prompts)

    #expect(try await fixture.reader.transcript(of: id).sessionID == id)
  }

  @Test("the timestamps of the entries do not go back")
  func timestampsDoNotGoBack() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = try await fixture.recorded.makeRecordedSession(prompts: Self.prompts)

    let stamps = try await fixture.reader.transcript(of: id).entries.map(\.timestamp)

    #expect(stamps == stamps.sorted())
    #expect(stamps.allSatisfy { $0.timeIntervalSince1970 > 0 })
  }

  @Test("the payload of a prompt entry holds the text of the prompt")
  func promptPayloadHoldsTheText() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = try await fixture.recorded.makeRecordedSession(prompts: Self.prompts)

    let entries = try await fixture.reader.transcript(of: id).entries
    let texts = entries.filter { $0.kind == "prompt" }.compactMap {
      Self.payloadText("text", of: $0)
    }

    #expect(texts == Self.prompts)
  }

  @Test("a read of one session gives no event of another session")
  func readOfOneSessionGivesNoOtherSession() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.recorded.makeRecordedSession(prompts: ["other session"])
    let id = try await fixture.recorded.makeRecordedSession(prompts: Self.prompts)

    let transcript = try await fixture.reader.transcript(of: id)
    let ownIDs = transcript.entries.compactMap { Self.payloadText("sessionId", of: $0) }

    #expect(!ownIDs.isEmpty)
    #expect(ownIDs.allSatisfy { $0 == id.description })
  }

  // MARK: - The mapping

  /// The lines of a `transcript.jsonl` that hold the two partial kinds of
  /// a running session and a response.
  private static func handWrittenLines(sessionID: ULID, routerID: ULID) -> String {
    let common = #""routerId":"\#(routerID)","sessionId":"\#(sessionID)""#
    return [
      #"{\#(common),"seq":0,"ts":"2026-11-03T10:00:00.000Z","kind":"promptStarted","text":"started"}"#,
      #"{\#(common),"seq":1,"ts":"2026-11-03T10:00:01.000Z","kind":"toolCallStarted","text":null,"tokensIn":3,"ms":1}"#,
      #"{\#(common),"seq":2,"ts":"2026-11-03T10:00:02.500Z","kind":"response","text":"done","decodeMs":1}"#,
    ].joined(separator: "\n") + "\n"
  }

  @Test("the partial kinds of a running session map to entries with their kind name")
  func partialKindsMapToEntries() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = ULID()
    let folder = fixture.recorded.root.appendingPathComponent(id.description, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Self.handWrittenLines(sessionID: id, routerID: ULID()).write(
      to: folder.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

    let entries = try await fixture.reader.transcript(of: id).entries

    #expect(entries.map(\.kind) == ["promptStarted", "toolCallStarted", "response"])
  }

  @Test("a timestamp keeps the millisecond that the recorder wrote")
  func timestampKeepsTheMillisecond() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = ULID()
    let folder = fixture.recorded.root.appendingPathComponent(id.description, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Self.handWrittenLines(sessionID: id, routerID: ULID()).write(
      to: folder.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

    let last = try await fixture.reader.transcript(of: id).entries.last?.timestamp

    let expected = ISO8601DateFormatter()
    expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(last == expected.date(from: "2026-11-03T10:00:02.500Z"))
  }

  @Test("a JSON array, a fraction and a null map to values that OperationValue can hold")
  func jsonShapesMapToOperationValues() throws {
    let json = Data(#"{"list":["a",2],"ratio":0.5,"gone":null,"flag":true,"count":3}"#.utf8)

    let value = try TranscriptEntryMapping.operationValue(fromJSON: json)

    #expect(
      value
        == .object([
          "list": .object(["0": .string("a"), "1": .int(2)]),
          "ratio": .string("0.5"),
          "flag": .bool(true),
          "count": .int(3),
        ]))
  }

  // MARK: - The unknown id and the cache

  @Test("an unknown id throws notFound")
  func unknownIDThrowsNotFound() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let unknown = ULID()

    await #expect(throws: SessionTranscriptError.notFound(unknown)) {
      _ = try await fixture.reader.transcript(of: unknown)
    }
  }

  @Test("a second read of a session does not resolve the roots again")
  func secondReadUsesTheCache() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = try await fixture.recorded.makeRecordedSession(prompts: Self.prompts)

    _ = try await fixture.reader.transcript(of: id)
    _ = try await fixture.reader.transcript(of: id)

    #expect(fixture.resolutions.count == 1)
  }

  @Test("a session folder that was deleted after a read throws notFound")
  func deletedFolderThrowsNotFound() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let id = try await fixture.recorded.makeRecordedSession(prompts: Self.prompts)
    _ = try await fixture.reader.transcript(of: id)
    try FileManager.default.removeItem(
      at: fixture.recorded.root.appendingPathComponent(id.description, isDirectory: true))

    await #expect(throws: SessionTranscriptError.notFound(id)) {
      _ = try await fixture.reader.transcript(of: id)
    }
  }

  // MARK: - A running session

  @Test("a running session gives the events on disk and no error")
  func runningSessionGivesTheEventsOnDisk() async throws {
    let fixture = try await Self.makeFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recorded.profile.standard.makeSession(
      workingDirectory: fixture.recorded.workingDirectory, recordingRoot: fixture.recorded.root)
    _ = try await session.respond(to: Self.prompts[0])

    let entries = try await fixture.reader.transcript(of: session.id).entries
    await session.close()

    #expect(entries.contains { $0.kind == "prompt" })
  }
}
