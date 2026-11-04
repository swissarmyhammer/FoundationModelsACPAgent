import Foundation
import Testing

@testable import FoundationModelsACPAgent

/// The JSON of ``SentMessageRecord`` is the wire shape that the peer client reads. The keys and
/// the values must not change when the type changes.
@Suite struct SentMessageRecordTests {
  /// The id of the mail in every test.
  private static let mailId = "01MSGMAIL0000000000000000A"

  /// The id of the receiver session in every test.
  private static let sessionId = "receiver-session"

  /// The id of the receiver run in the test of a message to a child.
  private static let runId = "run-1"

  /// The JSON of a message to a child, with the keys in sorted order.
  private static let toChildJSON =
    #"{"direction":"toChild","mailId":"\#(mailId)","receiverRunId":"\#(runId)","receiverSessionId":"\#(sessionId)"}"#

  /// The JSON of a message to a caller, with the keys in sorted order. It has no run id key.
  private static let toCallerJSON =
    #"{"direction":"toCaller","mailId":"\#(mailId)","receiverSessionId":"\#(sessionId)"}"#

  /// Encodes a record with sorted keys.
  private func json(of record: SentMessageRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(record), as: UTF8.self)
  }

  /// Decodes a record from text.
  private func record(from json: String) throws -> SentMessageRecord {
    try JSONDecoder().decode(SentMessageRecord.self, from: Data(json.utf8))
  }

  @Test("a message to a child encodes the direction, the run id and the session id")
  func aMessageToAChildEncodesTheWireShape() throws {
    let record = SentMessageRecord(
      mailId: Self.mailId, receiver: .run(id: Self.runId), receiverSessionId: Self.sessionId)

    #expect(try json(of: record) == Self.toChildJSON)
  }

  @Test("a message to a caller encodes the direction and no run id")
  func aMessageToACallerEncodesTheWireShape() throws {
    let record = SentMessageRecord(
      mailId: Self.mailId, receiver: .caller, receiverSessionId: Self.sessionId)

    #expect(try json(of: record) == Self.toCallerJSON)
  }

  @Test("the JSON of a message to a child decodes to the run receiver")
  func theJSONOfAMessageToAChildDecodes() throws {
    let decoded = try record(from: Self.toChildJSON)

    #expect(decoded.receiver == .run(id: Self.runId))
    #expect(decoded.mailId == Self.mailId)
    #expect(decoded.receiverSessionId == Self.sessionId)
  }

  @Test("the JSON of a message to a caller decodes to the caller receiver")
  func theJSONOfAMessageToACallerDecodes() throws {
    let decoded = try record(from: Self.toCallerJSON)

    #expect(decoded.receiver == .caller)
    #expect(decoded.mailId == Self.mailId)
    #expect(decoded.receiverSessionId == Self.sessionId)
  }

  @Test("a message to a child with no run id does not decode")
  func aChildWithNoRunIdIsRejected() {
    let json =
      #"{"direction":"toChild","mailId":"\#(Self.mailId)","receiverSessionId":"\#(Self.sessionId)"}"#

    #expect(throws: DecodingError.self) { try record(from: json) }
  }

  @Test("a message to a caller with a run id does not decode")
  func aCallerWithARunIdIsRejected() {
    let json =
      #"{"direction":"toCaller","mailId":"\#(Self.mailId)","receiverRunId":"\#(Self.runId)","receiverSessionId":"\#(Self.sessionId)"}"#

    #expect(throws: DecodingError.self) { try record(from: json) }
  }
}
