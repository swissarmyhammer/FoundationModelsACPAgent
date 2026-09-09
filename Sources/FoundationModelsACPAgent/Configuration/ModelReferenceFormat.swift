import FoundationModelsRouter

/// The shape of a model reference, which this package states one time and
/// every reader takes from here: `owner/name`, and after it the revision a
/// reference pins, behind `@`.
///
/// Router's `ModelRef` is the owner of the format. It parses the same two
/// separators, but it keeps its `repo` part, its `revision` part and the
/// separator between them to itself, so no other package can read them. Thus
/// this package states the format here, beside the `profile:` section whose
/// slots hold the references, and no reader states it a second time. A change
/// to the format goes in this one file.
enum ModelReferenceFormat {
    /// The separator between the owner and the name of a repository id.
    static let ownerSeparator: Character = "/"

    /// The separator between the repository id and the revision a reference
    /// pins.
    static let revisionSeparator: Character = "@"

    /// The repository id and the revision of one reference.
    ///
    /// - Parameter reference: The reference to split.
    /// - Returns: The repository id, and the revision when the reference pins
    ///   one.
    static func parts(of reference: ModelRef) -> (repo: String, revision: String?) {
        let text = reference.stringValue
        guard let separator = text.firstIndex(of: revisionSeparator) else {
            return (text, nil)
        }
        return (String(text[..<separator]), String(text[text.index(after: separator)...]))
    }
}
