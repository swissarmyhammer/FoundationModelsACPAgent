import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// Why an event or a JSON text cannot become a session transcript entry.
enum TranscriptEntryMappingError: Error, Equatable, Sendable {
  /// The JSON text has no value that ``OperationValue`` can hold at its
  /// top level, for example a bare `null`.
  case notRepresentable
}

/// The mapping of a recorded ``TranscriptEvent`` to the
/// ``SessionTranscriptEntry`` that a tool reads.
///
/// The mapping is generic. It does not look at the kind of the event: it
/// encodes the event with its own `Codable` form and keeps every field. So
/// a new kind, for example `toolCallStarted` or `promptStarted`, or a new
/// field of a kind, needs no change here.
///
/// ``OperationValue`` holds a string, a whole number, a flag and an object.
/// It holds no array, no fraction and no null. So the mapping makes these
/// changes to the JSON of an event:
/// - An array becomes an object. Its keys are the decimal indexes `"0"`,
///   `"1"` and so on.
/// - A number with a fraction becomes a string with the decimal text.
/// - A null is left out, as the recorder leaves out an absent field.
enum TranscriptEntryMapping {
  /// The key of the recorded instant in the encoded event.
  private static let timestampKey = "ts"

  /// The key of the kind in the encoded event.
  private static let kindKey = "kind"

  /// Maps one recorded event to one entry.
  ///
  /// - Parameter event: The event that the Router recorded.
  /// - Returns: An entry with the kind name of the event, the instant that
  ///   the recorder stamped, and every other field of the event as the
  ///   payload.
  /// - Throws: The error of the encode of the event, or
  ///   ``TranscriptEntryMappingError/notRepresentable`` when the encoded
  ///   event is not a JSON object with a number for its instant.
  static func entry(from event: TranscriptEvent) throws -> SessionTranscriptEntry {
    var fields = try encodedFields(of: event)
    guard let seconds = fields.removeValue(forKey: timestampKey) as? Double else {
      throw TranscriptEntryMappingError.notRepresentable
    }
    fields.removeValue(forKey: kindKey)
    return SessionTranscriptEntry(
      kind: event.kind.rawValue,
      timestamp: Date(timeIntervalSinceReferenceDate: seconds),
      payload: operationValue(from: fields) ?? .object([:]))
  }

  /// Reads a JSON text as an ``OperationValue``, with the changes that the
  /// type documents.
  ///
  /// - Parameter json: The UTF-8 JSON text.
  /// - Returns: The value of the text.
  /// - Throws: The error of the JSON parse, or
  ///   ``TranscriptEntryMappingError/notRepresentable`` for a text that has
  ///   no value to hold.
  static func operationValue(fromJSON json: Data) throws -> OperationValue {
    let parsed = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
    guard let value = operationValue(from: parsed) else {
      throw TranscriptEntryMappingError.notRepresentable
    }
    return value
  }

  /// The fields of the event, as the `Codable` form of the event writes
  /// them. The instant is a number of seconds from the reference date, the
  /// default form of a `Date`, which loses no digit.
  private static func encodedFields(of event: TranscriptEvent) throws -> [String: Any] {
    let data = try JSONEncoder().encode(event)
    guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TranscriptEntryMappingError.notRepresentable
    }
    return fields
  }

  /// The value of one parsed JSON node, or `nil` for a null.
  private static func operationValue(from node: Any) -> OperationValue? {
    switch node {
    case let object as [String: Any]:
      return .object(object.compactMapValues { operationValue(from: $0) })
    case let array as [Any]:
      return .object(indexedFields(of: array))
    case let text as String:
      return .string(text)
    case let number as NSNumber:
      return numberValue(number)
    default:
      return nil
    }
  }

  /// The fields of an array, keyed by the decimal index of each element.
  private static func indexedFields(of array: [Any]) -> [String: OperationValue] {
    var fields: [String: OperationValue] = [:]
    for (index, element) in array.enumerated() {
      fields[String(index)] = operationValue(from: element)
    }
    return fields
  }

  /// The value of a parsed number: a flag, a whole number, or the decimal
  /// text of a number with a fraction.
  private static func numberValue(_ number: NSNumber) -> OperationValue {
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .bool(number.boolValue)
    }
    if CFNumberIsFloatType(number) {
      return .string(number.stringValue)
    }
    return .int(number.intValue)
  }
}
