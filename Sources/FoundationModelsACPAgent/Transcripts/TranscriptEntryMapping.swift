import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// Why an event cannot become a session transcript entry.
enum TranscriptEntryMappingError: Error, Equatable, Sendable {
  /// The encoded event is not a JSON object with a number for its instant.
  case notRepresentable
}

/// The mapping of a recorded ``TranscriptEvent`` to the ``SessionTranscriptEntry`` that a tool
/// reads.
///
/// The mapping is generic. It does not look at the kind of the event: it encodes the event with its
/// own `Codable` form and keeps every field. So a new kind, for example `modelChanged`,
/// `toolCallStarted` or `promptStarted`, or a new field of a kind, needs no change here.
///
/// ``OperationValue`` holds a string, a whole number, a flag and an object. It holds no array, no
/// fraction and no null. So the mapping makes these changes to the JSON of an event. Each change
/// loses some information, and a tool must know it:
/// - The kind and the instant leave the payload. The kind is the name of the entry. The instant is
///   the timestamp of the entry, and it keeps the millisecond that the recorder wrote.
/// - An array becomes an object. Its keys are the decimal indexes of the elements, in the order of
///   the elements, with zeros at the front so that all keys have the width of the largest index.
///   So the text order of the keys is the order of the elements (`"00"`, `"01"` ... `"11"` for
///   twelve elements). An array of up to ten elements has the keys `"0"` to `"9"`.
/// - A null is left out, as the recorder leaves out an absent field. A null in an array is left
///   out, and the next elements take its place: the keys have no gap.
/// - An empty array is left out too. So a tool cannot tell an empty array from an absent field,
///   and an empty object stays an object with no key.
/// - A field of type `Double` (for example `temperature`) is always a string with the shortest
///   decimal text that reads back as the same number (`"0.7"`, `"1.0"`), so the type does not
///   depend on the value. The mapping finds these fields in the event, not by a list of names.
/// - A whole number that `Int` cannot hold is a string with its digits. It does not wrap.
enum TranscriptEntryMapping {
  /// The key of the recorded instant in the encoded event.
  private static let timestampKey = "ts"

  /// The key of the kind in the encoded event.
  private static let kindKey = "kind"

  /// Maps one recorded event to one entry.
  ///
  /// - Parameter event: The event that the Router recorded.
  /// - Returns: An entry with the kind name of the event, the instant that the recorder stamped,
  ///   and every other field of the event as the payload.
  /// - Throws: The error of the encode of the event, or
  ///   ``TranscriptEntryMappingError/notRepresentable`` when the encoded event is not a JSON
  ///   object with a number for its instant.
  static func entry(from event: TranscriptEvent) throws -> SessionTranscriptEntry {
    var fields = try encodedFields(of: event)
    guard let seconds = fields.removeValue(forKey: timestampKey) as? Double else {
      throw TranscriptEntryMappingError.notRepresentable
    }
    fields.removeValue(forKey: kindKey)
    return SessionTranscriptEntry(
      kind: event.kind.rawValue,
      timestamp: Date(timeIntervalSinceReferenceDate: seconds),
      payload: operationValue(from: fields, doubleFields: doubleFieldNames(in: event))
        ?? .object([:]))
  }

  /// The value of one parsed JSON node, with the changes that the type documents.
  ///
  /// - Parameters:
  ///   - node: The node that `JSONSerialization` parsed.
  ///   - doubleFields: The names of the fields of type `Double`.
  ///   - key: The name of the field that holds the node, or `nil` at the top.
  /// - Returns: The value, or `nil` for a null and for an empty array.
  static func operationValue(
    from node: Any, doubleFields: Set<String>, key: String? = nil
  ) -> OperationValue? {
    switch node {
    case let object as [String: Any]:
      return .object(fields(of: object, doubleFields: doubleFields))
    case let array as [Any]:
      return indexedValue(of: array, doubleFields: doubleFields, key: key)
    case let text as String:
      return .string(text)
    case let number as NSNumber:
      return numberValue(number, isDoubleField: key.map(doubleFields.contains) ?? false)
    default:
      return nil
    }
  }

  /// The fields of the event, as the `Codable` form of the event writes them. The instant is a
  /// number of seconds from the reference date, the default form of a `Date`, which loses no digit.
  private static func encodedFields(of event: TranscriptEvent) throws -> [String: Any] {
    let data = try JSONEncoder().encode(event)
    guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw TranscriptEntryMappingError.notRepresentable
    }
    return fields
  }

  /// The fields of a parsed object, each with the name of its field. A null is left out.
  private static func fields(
    of object: [String: Any], doubleFields: Set<String>
  ) -> [String: OperationValue] {
    var fields: [String: OperationValue] = [:]
    for (name, node) in object {
      fields[name] = operationValue(from: node, doubleFields: doubleFields, key: name)
    }
    return fields
  }

  /// The value of an array: an object with the padded index of each element as the key. A null is
  /// left out first, so the keys have no gap. An array with no element gives `nil`.
  private static func indexedValue(
    of array: [Any], doubleFields: Set<String>, key: String?
  ) -> OperationValue? {
    let elements = array.compactMap {
      operationValue(from: $0, doubleFields: doubleFields, key: key)
    }
    guard !elements.isEmpty else { return nil }
    let width = String(elements.count - 1).count
    var fields: [String: OperationValue] = [:]
    for (index, element) in elements.enumerated() {
      let digits = String(index)
      fields[String(repeating: "0", count: width - digits.count) + digits] = element
    }
    return .object(fields)
  }

  /// The value of a parsed number: a flag, a whole number, or a string. The string is for a field
  /// of type `Double`, for a number with a fraction, and for a whole number that `Int` cannot hold.
  private static func numberValue(_ number: NSNumber, isDoubleField: Bool) -> OperationValue {
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .bool(number.boolValue)
    }
    if isDoubleField || CFNumberIsFloatType(number) {
      return .string("\(number.doubleValue)")
    }
    if NSNumber(value: number.intValue) != number {
      return .string(number.stringValue)
    }
    return .int(number.intValue)
  }

  /// The names of the fields of type `Double` or `Float` in `value`, found by reflection. A
  /// synthesized `Codable` writes a field under the name of the field.
  private static func doubleFieldNames(in value: Any) -> Set<String> {
    var names: Set<String> = []
    collectDoubleFields(in: value, name: nil, into: &names)
    return names
  }

  /// Walks the fields of `value` and adds the name of each field of type `Double` or `Float`.
  /// An optional, an array and a dictionary pass their name to their elements.
  private static func collectDoubleFields(
    in value: Any, name: String?, into names: inout Set<String>
  ) {
    if value is Double || value is Float {
      if let name { names.insert(name) }
      return
    }
    let mirror = Mirror(reflecting: value)
    let passesName =
      mirror.displayStyle == .optional || mirror.displayStyle == .collection
      || mirror.displayStyle == .set
    for child in mirror.children {
      collectDoubleFields(in: child.value, name: passesName ? name : child.label, into: &names)
    }
  }
}
