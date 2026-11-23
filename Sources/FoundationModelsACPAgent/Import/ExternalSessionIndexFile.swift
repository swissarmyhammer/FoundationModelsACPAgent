import ACPImport
import Foundation
import FoundationModelsExtras

/// The index file of one source agent (D212, section 4.1): `external-sessions/<source>.jsonl`
/// in ``AgentHome/local``.
///
/// The first line is the header: the format number, the source and the path of the root. Each
/// other line is one ``ExternalSessionSummary`` as JSON. A file with a different format number,
/// with the header of a different root, or with a line that does not parse gives no entry: the
/// index then builds again, with no error. There is no migration.
enum ExternalSessionIndexFile {
  /// The format number of the files that this code writes.
  static let formatNumber = 1

  /// The first line of an index file.
  private struct Header: Codable, Equatable {
    /// The format number.
    let format: Int

    /// The source agent.
    let source: String

    /// The path of the root.
    let root: String
  }

  /// The line break byte.
  private static let lineBreak = UInt8(ascii: "\n")

  /// The index file of a source agent in the folder of the index files.
  ///
  /// - Parameters:
  ///   - agent: The source agent.
  ///   - folder: The folder of the index files.
  /// - Returns: The file.
  static func file(of agent: ImportSourceAgent, in folder: URL) -> URL {
    folder.appendingPathComponent(agent.rawValue, isDirectory: false)
      .appendingPathExtension(ImportSourceLayout.fileExtension)
  }

  /// The JSON line of one summary, with no line break.
  ///
  /// - Parameter summary: The summary.
  /// - Returns: The line. A summary that does not encode gives an empty line, which the write
  ///   leaves out.
  static func line(of summary: ExternalSessionSummary) -> Data {
    (try? JSONEncoder().encode(summary)) ?? Data()
  }

  /// The bytes of an index file.
  ///
  /// - Parameters:
  ///   - agent: The source agent.
  ///   - root: The root of the agent.
  ///   - lines: The line of each entry.
  /// - Returns: The bytes.
  static func data(of agent: ImportSourceAgent, root: URL, lines: [Data]) -> Data {
    let header = Header(format: formatNumber, source: agent.rawValue, root: root.path)
    let headerLine = (try? JSONEncoder().encode(header)) ?? Data()
    // One append for each line copies the bytes of the line at once. A generic join copies
    // one byte at a time, which costs seconds for an index of 30,000 entries.
    var start = Data(capacity: lines.reduce(headerLine.count + 1) { $0 + $1.count + 1 })
    start.append(headerLine)
    start.append(lineBreak)
    return lines.filter { !$0.isEmpty }.reduce(into: start) { data, line in
      data.append(line)
      data.append(lineBreak)
    }
  }

  /// The entries of an index file, by path.
  ///
  /// - Parameters:
  ///   - data: The bytes of the file.
  ///   - agent: The source agent.
  ///   - root: The root of the agent now.
  /// - Returns: The entries, or `nil` when the file has a different format number, the header
  ///   of a different source or root, or a line that does not parse.
  static func entries(in data: Data, of agent: ImportSourceAgent, root: URL)
    -> [String: ExternalSessionIndexEntry]?
  {
    let lines = data.split(separator: lineBreak, omittingEmptySubsequences: true)
    let expected = Header(format: formatNumber, source: agent.rawValue, root: root.path)
    guard let first = lines.first,
      (try? JSONDecoder().decode(Header.self, from: Data(first))) == expected
    else { return nil }
    let decoder = JSONDecoder()
    guard
      let entries = try? lines.dropFirst().map({ line in
        try entry(of: Data(line), agent: agent, decoder: decoder)
      })
    else { return nil }
    return Dictionary(entries.map { ($0.summary.path, $0) }) { _, last in last }
  }

  /// The error of a line of an index file that holds no entry of the source agent.
  private struct ForeignLine: Error {}

  /// The entry of one line of an index file.
  ///
  /// - Parameters:
  ///   - line: The line, with no line break.
  ///   - agent: The source agent of the file.
  ///   - decoder: The decoder.
  /// - Returns: The entry.
  /// - Throws: The error of the decode, or ``ForeignLine`` for a summary of a different source.
  private static func entry(of line: Data, agent: ImportSourceAgent, decoder: JSONDecoder) throws
    -> ExternalSessionIndexEntry
  {
    let summary = try decoder.decode(ExternalSessionSummary.self, from: line)
    guard summary.source == agent.rawValue else { throw ForeignLine() }
    return ExternalSessionIndexEntry(summary: summary, line: line)
  }
}
