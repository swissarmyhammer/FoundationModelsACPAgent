/// A cheap stamp of one domain of the content catalog of a host (D214): for example the turns of
/// one session.
///
/// The host keeps the stamp of each domain that it wrote to Spotlight. When the stamp that the
/// agent gives now is not the same, the domain changed, and the host reads its records again. A
/// stamp is the same for the same records, also in the next launch of the process: it is a hash
/// of stable facts of the records, never a value of the process.
public struct ContentStamp: Hashable, Sendable, Codable, CustomStringConvertible {
  /// The text of the stamp. Its form is not part of the API: compare two stamps, do not parse
  /// one.
  public let value: String

  /// Makes a stamp from its text.
  ///
  /// - Parameter value: The text of the stamp.
  public init(value: String) {
    self.value = value
  }

  /// The text of the stamp.
  public var description: String { value }

  /// The stamp of a sequence of facts: the FNV-1a hash (64 bits) of each fact in order, with a
  /// separator after each one.
  ///
  /// - Parameter facts: The facts, in a stable order.
  /// - Returns: The stamp.
  static func hashing(_ facts: [String]) -> ContentStamp {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in facts.joined(separator: "\u{1F}").utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    let hex = String(hash, radix: 16)
    return ContentStamp(value: String(repeating: "0", count: 16 - hex.count) + hex)
  }
}
