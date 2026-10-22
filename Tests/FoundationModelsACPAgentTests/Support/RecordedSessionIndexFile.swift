import Foundation
import FoundationModelsExtras
import Testing

/// The reader of the recorded `index.md` of each session folder: the file
/// whose YAML frontmatter holds the record of one session.
///
/// Router keeps most stored properties of `SessionRecord` internal — the
/// configuration envelope among them — so a proof decodes only the slice of
/// the frontmatter it needs, as a `Decodable` type of its own.
enum RecordedSessionIndexFile {
    /// The name of the record file in each session folder.
    static let fileName = "index.md"

    /// The `index.md` of one session folder: `<root>/<sessionId>/`, and
    /// ``fileName`` inside it.
    ///
    /// - Parameters:
    ///   - sessionId: The session, whose id names its folder.
    ///   - root: The recording root that holds the folder.
    /// - Returns: The file URL, whether or not anything stands there.
    static func fileURL(ofSession sessionId: String, under root: URL) -> URL {
        root
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The frontmatter of one session's `index.md`, decoded as `Slice`.
    ///
    /// - Parameters:
    ///   - sessionId: The session, whose id names its folder.
    ///   - root: The recording root that holds the folder.
    ///   - type: The slice type to decode.
    /// - Returns: The decoded slice.
    /// - Throws: The read, the parse or the decode error, or a failed
    ///   requirement when the file holds no frontmatter.
    static func slice<Slice: Decodable>(
        ofSession sessionId: String, under root: URL, as type: Slice.Type
    ) throws -> Slice {
        try slice(of: fileURL(ofSession: sessionId, under: root), as: type)
    }

    /// The frontmatter of each `index.md` under `root`, at any depth,
    /// decoded as `Slice`, in walk order.
    ///
    /// - Parameters:
    ///   - root: The recording root to walk.
    ///   - type: The slice type to decode.
    /// - Returns: One slice for each `index.md`.
    /// - Throws: A failed requirement when `root` cannot be walked, or the
    ///   error of ``slice(of:as:)`` for a file.
    static func slices<Slice: Decodable>(under root: URL, as type: Slice.Type) throws -> [Slice] {
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try walker.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == fileName }
            .map { file in try slice(of: file, as: type) }
    }

    /// The frontmatter of one `index.md`, decoded as `Slice`.
    ///
    /// - Parameters:
    ///   - file: The `index.md`.
    ///   - type: The slice type to decode.
    /// - Returns: The decoded slice.
    /// - Throws: The read, the parse or the decode error, or a failed
    ///   requirement when the file holds no frontmatter.
    static func slice<Slice: Decodable>(of file: URL, as type: Slice.Type) throws -> Slice {
        let text = try String(contentsOf: file, encoding: .utf8)
        let frontmatter = try #require(FrontmatterDocument<Never>.split(text: text).frontmatter)
        return try YAMLValue.parse(frontmatter).decoded(as: type)
    }
}
