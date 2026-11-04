import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The mapping of a recorded event to an entry (``TranscriptEntryMapping``):
/// one entry for each kind, and the shapes that `OperationValue` cannot hold.
///
/// `TranscriptEvent` has no public init. So each event here is a line of a
/// `transcript.jsonl` that Router reads back.
@Suite struct TranscriptEntryMappingTests {
  /// The session of every event of this suite.
  private static let sessionID = ULID()

  /// The router of every event of this suite.
  private static let routerID = ULID()

  /// The text of the instant of every event.
  private static let instantText = "2026-11-03T10:00:00.250Z"

  /// The instant of every event, as a date.
  private static var instant: Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: instantText) ?? .distantPast
  }

  /// A line of a `transcript.jsonl`.
  ///
  /// - Parameters:
  ///   - kind: The kind name.
  ///   - sequence: The `seq` of the event.
  ///   - extra: More JSON members, as text that starts with a comma, or empty.
  private static func line(kind: String, sequence: Int = 0, extra: String = "") -> String {
    #"{"routerId":"\#(routerID)","sessionId":"\#(sessionID)","seq":\#(sequence),"ts":"\#(instantText)","kind":"\#(kind)"\#(extra)}"#
  }

  /// Reads the events of the lines through Router, from a folder.
  private static func events(of lines: [String]) throws -> [TranscriptEvent] {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("TranscriptEntryMappingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try (lines.joined(separator: "\n") + "\n").write(
      to: folder.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
    return try TranscriptEvent.read(sessionDirectory: folder)
  }

  /// The entry of the one event in `line`.
  private static func entry(of line: String) throws -> SessionTranscriptEntry {
    let event = try #require(try events(of: [line]).first)
    return try TranscriptEntryMapping.entry(from: event)
  }

  /// The value at a path of keys in the payload of an entry.
  private static func value(_ path: [String], in entry: SessionTranscriptEntry) -> OperationValue? {
    var current: OperationValue? = entry.payload
    for key in path {
      guard case .object(let fields)? = current else { return nil }
      current = fields[key]
    }
    return current
  }

  /// The sorted keys of an object value, or none for another value.
  private static func keys(of value: OperationValue?) -> [String] {
    if case .object(let fields)? = value { return fields.keys.sorted() }
    return []
  }

  // MARK: - Every kind

  /// The name of each kind. The switch has no `default`: a new kind stops the build of this test,
  /// and the author adds the kind to ``allKindNames``.
  private static func isListed(_ kind: TranscriptEvent.Kind) -> Bool {
    switch kind {
    case .session, .instructions, .prompt, .toolCalls, .toolOutput, .response, .reasoning,
      .embedding, .divergence, .modelChanged, .generationCall, .repeatedPartRemoval, .watchStop,
      .mail, .toolCallStarted, .promptStarted, .toolCall, .unknown:
      return allKindNames.contains(kind.rawValue)
    }
  }

  /// The raw name of every kind of `TranscriptEvent.Kind`.
  private static let allKindNames = [
    "session", "instructions", "prompt", "toolCalls", "toolOutput", "response", "reasoning",
    "embedding", "divergence", "modelChanged", "generationCall", "repeatedPartRemoval",
    "watchStop", "mail", "toolCallStarted", "promptStarted", "toolCall", "unknown",
  ]

  @Test("the list of kind names holds every kind", arguments: allKindNames)
  func listHoldsEveryKind(name: String) throws {
    let kind = try #require(TranscriptEvent.Kind(rawValue: name))

    #expect(Self.isListed(kind))
  }

  @Test("each kind maps to an entry with its kind name", arguments: allKindNames)
  func eachKindMapsToItsName(name: String) throws {
    let entry = try Self.entry(of: Self.line(kind: name))

    #expect(entry.kind == name)
  }

  @Test("each kind keeps the session and the sequence in the payload", arguments: allKindNames)
  func eachKindKeepsSessionAndSequence(name: String) throws {
    let entry = try Self.entry(of: Self.line(kind: name, sequence: 7))

    #expect(Self.value(["sessionId"], in: entry) == .string(Self.sessionID.description))
    #expect(Self.value(["seq"], in: entry) == .int(7))
  }

  @Test("the payload of a model change keeps the text and the model")
  func modelChangedKeepsText() throws {
    let entry = try Self.entry(
      of: Self.line(kind: "modelChanged", extra: #","text":"standard to flash","slot":"flash""#))

    #expect(Self.value(["text"], in: entry) == .string("standard to flash"))
    #expect(Self.value(["slot"], in: entry) == .string("flash"))
  }

  @Test("the instant keeps the millisecond and the payload holds no instant")
  func instantKeepsMillisecond() throws {
    let entry = try Self.entry(of: Self.line(kind: "prompt"))

    #expect(entry.timestamp == Self.instant)
    #expect(Self.value(["ts"], in: entry) == nil)
    #expect(Self.value(["kind"], in: entry) == nil)
  }

  // MARK: - The shapes that OperationValue cannot hold

  @Test("a temperature of 0.7 is a string")
  func fractionTemperatureIsString() throws {
    let entry = try Self.entry(
      of: Self.line(
        kind: "prompt", extra: #","entry":{"entryId":"e","options":{"temperature":0.7}}"#))

    #expect(Self.value(["entry", "options", "temperature"], in: entry) == .string("0.7"))
  }

  @Test("a temperature of 1.0 is a string too, so the type does not depend on the value")
  func wholeTemperatureIsString() throws {
    let entry = try Self.entry(
      of: Self.line(
        kind: "prompt", extra: #","entry":{"entryId":"e","options":{"temperature":1.0}}"#))

    #expect(Self.value(["entry", "options", "temperature"], in: entry) == .string("1.0"))
  }

  @Test("a whole number field stays a whole number")
  func wholeNumberStays() throws {
    let entry = try Self.entry(
      of: Self.line(
        kind: "prompt",
        extra: #","entry":{"entryId":"e","options":{"maximumResponseTokens":5}}"#))

    #expect(Self.value(["entry", "options", "maximumResponseTokens"], in: entry) == .int(5))
  }

  @Test("the tool calls of an entry become an object with the keys 0 and 1")
  func toolCallsBecomeIndexedObject() throws {
    let calls =
      #"[{"id":"c1","toolName":"first","argumentsJSON":"{}"},{"id":"c2","toolName":"second","argumentsJSON":"{}"}]"#
    let entry = try Self.entry(
      of: Self.line(kind: "toolCalls", extra: #","entry":{"entryId":"e","toolCalls":\#(calls)}"#))

    #expect(Self.value(["entry", "toolCalls", "0", "toolName"], in: entry) == .string("first"))
    #expect(Self.value(["entry", "toolCalls", "1", "toolName"], in: entry) == .string("second"))
  }

  @Test("an empty array is left out, as an absent field is")
  func emptyArrayIsLeftOut() throws {
    let entry = try Self.entry(
      of: Self.line(kind: "toolCalls", extra: #","entry":{"entryId":"e","toolCalls":[]}"#))

    #expect(Self.value(["entry", "toolCalls"], in: entry) == nil)
  }

  /// The value of the parsed JSON text, with no field of type `Double`.
  private static func mapped(_ json: String) throws -> OperationValue? {
    let parsed = try JSONSerialization.jsonObject(
      with: Data(json.utf8), options: [.fragmentsAllowed])
    return TranscriptEntryMapping.operationValue(from: parsed, doubleFields: [])
  }

  @Test("a null in an array leaves no gap in the keys")
  func nullInArrayLeavesNoGap() throws {
    #expect(
      try Self.mapped(#"["a",null,"b"]"#) == .object(["0": .string("a"), "1": .string("b")]))
  }

  @Test("a whole number that Int cannot hold is a string and does not wrap")
  func largeNumberIsString() throws {
    #expect(try Self.mapped("18446744073709551615") == .string("18446744073709551615"))
  }

  @Test("the keys of an array of twelve elements sort in the order of the elements")
  func keysSortInElementOrder() throws {
    let elements = (0..<12).map { "\"v\($0)\"" }.joined(separator: ",")
    let value = try Self.mapped("[\(elements)]")

    #expect(Self.keys(of: value) == (0..<12).map { String(format: "%02d", $0) })
  }

  @Test("a null at the top is no value")
  func nullHasNoValue() throws {
    #expect(try Self.mapped("null") == nil)
  }
}
