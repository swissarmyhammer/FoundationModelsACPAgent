import Foundation

/// The `--json` document of a reporting subcommand (cli-plan.md §5.6): one
/// encoder, so that `config show --json` and `snapshots list --json` give
/// the same form.
enum JSONDocument {
    /// The JSON text of `document`: pretty, keys sorted, slashes plain, dates
    /// in ISO 8601, and newline-terminated, so a shell prompt starts on its
    /// own line.
    ///
    /// - Parameter document: The value to encode.
    /// - Returns: The JSON text.
    /// - Throws: The encoding error.
    static func text(of document: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(document), as: UTF8.self) + "\n"
    }
}
