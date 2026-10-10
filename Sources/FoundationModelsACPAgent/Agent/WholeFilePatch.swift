/// Renders one file change of a tool display as a patch in git's `--patch`
/// text format, the `git_patch` format of an ACP `Diff`.
///
/// A display diff carries the full text before and after the change, and no
/// hunks. So the patch has one hunk for the whole file: it removes each old
/// line and adds each new line. A client that applies or shows the patch gets
/// the correct result. The hunk is not minimal, because this package has no
/// line-diff algorithm, and a minimal hunk is not necessary for a correct
/// patch.
///
/// The headers name the path as it is given, with no `a/` or `b/` prefix,
/// because ACP requires an absolute path in a `git_patch`.
enum WholeFilePatch {
    /// The mode line of a new file. A display diff carries no mode, so a new
    /// file gets the mode of a regular file.
    private static let newFileModeLine = "new file mode 100644"

    /// The path git writes for the side of a change that has no file.
    private static let missingFilePath = "/dev/null"

    /// The line git writes after the last line of a side that does not end
    /// with a newline.
    private static let noNewlineMarker = "\\ No newline at end of file"

    /// The line separator of a patch and of the file texts.
    private static let newline = "\n"

    /// The patch text of one change, newline-terminated, or the empty string
    /// when the change does not change the text.
    ///
    /// - Parameters:
    ///   - path: The path of the file, written as it is into each header.
    ///   - oldText: The text before the change, or `nil` for a new file.
    ///   - newText: The text after the change.
    /// - Returns: The patch text.
    static func text(path: String, oldText: String?, newText: String) -> String {
        guard oldText != newText else { return "" }
        let old = PatchSide(text: oldText ?? "")
        let new = PatchSide(text: newText)
        var lines = ["diff --git \(path) \(path)"]
        if oldText == nil {
            lines.append(newFileModeLine)
        }
        lines.append("--- \(oldText == nil ? missingFilePath : path)")
        lines.append("+++ \(path)")
        // A new empty file has no line to add, so git writes no hunk.
        if !old.lines.isEmpty || !new.lines.isEmpty {
            lines.append("@@ -\(old.hunkRange) +\(new.hunkRange) @@")
            lines += old.markedLines(prefix: "-") + new.markedLines(prefix: "+")
        }
        return lines.joined(separator: newline) + newline
    }

    /// One side of a change: the lines of a file text, and whether the text
    /// ends with a newline.
    private struct PatchSide {
        /// The lines of the text, with no line separator.
        let lines: [Substring]

        /// Whether the text ends with a newline. An empty text counts as
        /// ending with one, because it has no last line to mark.
        let endsWithNewline: Bool

        /// Splits `text` into its lines.
        ///
        /// - Parameter text: The text of the file on this side.
        init(text: String) {
            endsWithNewline = text.isEmpty || text.hasSuffix(WholeFilePatch.newline)
            let parts = text.split(separator: WholeFilePatch.newline, omittingEmptySubsequences: false)
            lines = text.isEmpty ? [] : Array(endsWithNewline ? parts.dropLast() : parts[...])
        }

        /// The range of this side in a hunk header: `start,count`, with the
        /// count left out when it is one, as git writes it. A side with no
        /// lines starts at line zero.
        var hunkRange: String {
            switch lines.count {
            case 0: "0,0"
            case 1: "1"
            default: "1,\(lines.count)"
            }
        }

        /// The lines of this side in a hunk: each line after `prefix`, then
        /// the no-newline marker when the text does not end with a newline.
        ///
        /// - Parameter prefix: `-` for the old side, `+` for the new side.
        /// - Returns: The hunk lines.
        func markedLines(prefix: String) -> [String] {
            let marked = lines.map { prefix + $0 }
            return endsWithNewline ? marked : marked + [WholeFilePatch.noNewlineMarker]
        }
    }
}
