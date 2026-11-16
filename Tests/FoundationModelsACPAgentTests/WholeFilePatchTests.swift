import Testing

@testable import FoundationModelsACPAgent

/// The git patch of one file change of a tool display (``WholeFilePatch``):
/// one hunk for the whole file, in git's `--patch` text format. The
/// projection tests in `ToolDisplayProjectionTests` read the common shapes;
/// these tests read the edges.
@Suite struct WholeFilePatchTests {
  /// The absolute path of the changed file.
  private static let path = "/repo/notes.txt"

  /// The ACP form of a `git_patch` (`DiffPatchFormat.gitPatch`): each path
  /// is the absolute path of the change, with no `a/` or `b/` prefix, and
  /// `/dev/null` names the missing side of a new file. A reader of the
  /// patch must not need git's prefixes.
  @Test(arguments: [Optional("alpha\n"), nil])
  func eachPathIsTheAbsolutePathWithNoPrefix(oldText: String?) throws {
    let lines = WholeFilePatch.text(path: Self.path, oldText: oldText, newText: "beta\n")
      .split(separator: "\n").map(String.init)

    #expect(lines.first == "diff --git \(Self.path) \(Self.path)")
    let old = try #require(lines.first { $0.hasPrefix("--- ") })
    let new = try #require(lines.first { $0.hasPrefix("+++ ") })
    #expect(old == "--- " + (oldText == nil ? "/dev/null" : Self.path))
    #expect(new == "+++ " + Self.path)
    #expect(!lines.contains { $0.contains(" a/") || $0.contains(" b/") })
  }

  /// A change that keeps the text has nothing to report: the patch is
  /// empty, with no headers and no hunk, the same as git gives.
  @Test func aChangeThatKeepsTheTextGivesAnEmptyPatch() {
    #expect(WholeFilePatch.text(path: Self.path, oldText: "alpha\n", newText: "alpha\n") == "")
  }

  /// A new empty file has no line to add: the patch holds the headers of
  /// a new file and no hunk, the same as git gives.
  @Test func aNewEmptyFileGivesTheHeadersAndNoHunk() {
    #expect(
      WholeFilePatch.text(path: Self.path, oldText: nil, newText: "") == """
        diff --git \(Self.path) \(Self.path)
        new file mode 100644
        --- /dev/null
        +++ \(Self.path)

        """)
  }

  /// An old text with no newline at its end gets the marker after its
  /// last removed line, and the new side has no marker.
  @Test func anOldTextWithNoFinalNewlineGetsTheMarkerAfterItsLastLine() {
    #expect(
      WholeFilePatch.text(path: Self.path, oldText: "alpha", newText: "beta\n") == """
        diff --git \(Self.path) \(Self.path)
        --- \(Self.path)
        +++ \(Self.path)
        @@ -1 +1 @@
        -alpha
        \\ No newline at end of file
        +beta

        """)
  }
}
