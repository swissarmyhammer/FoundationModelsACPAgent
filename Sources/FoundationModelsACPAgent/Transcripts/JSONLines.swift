import Foundation
import os

/// The logger every warning of the transcripts module goes to, shared by
/// `SessionIndex` and `ProjectRegistry` so the subsystem and the category
/// exist once.
let transcriptLogger = Logger(subsystem: "FoundationModelsACPAgent", category: "Transcripts")

/// Shared plumbing for the two JSON-lines files this package writes:
/// `sessions.jsonl` (plan.md §4.3) and `projects.jsonl` (§4.5). One record
/// per line, RFC 3339 dates, keys in sorted order so a record's line is
/// stable across writes.
enum JSONLines {
    /// The byte that ends each record's line.
    static let newline = UInt8(ascii: "\n")

    /// The encoder every record line is written with: RFC 3339 dates and
    /// sorted keys, on one line.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The decoder every record line is read with: RFC 3339 dates.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes `record` as one newline-terminated line.
    static func encodedLine(of record: some Encodable) throws -> Data {
        var line = try makeEncoder().encode(record)
        line.append(newline)
        return line
    }

    /// Appends `line` to `file`, creating the file when it is absent. The
    /// parent directory must already exist.
    static func appendLine(_ line: Data, to file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            try line.write(to: file, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Best-effort close on the failure path; the write error is the
            // one the caller must see.
            try? handle.close()
            throw error
        }
        try handle.close()
    }
}
