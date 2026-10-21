import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// `SettingsTreeDifference` (EXTRAS-9 rule 9): the dotted key path of each
/// leaf key that one tree of a level adds, changes or removes, for the ids of
/// a change of a file.
@Suite struct SettingsTreeDifferenceTests {
    /// A tree with `compaction.trigger` and `tools.web.apiKeys.tavily`.
    private static let before: YAMLValue = .dictionary([
        "compaction": .dictionary(["trigger": .double(0.7)]),
        "tools": .dictionary(["web": .dictionary(["apiKeys": .dictionary(["tavily": .string("keychain:a")])])]),
    ])

    /// Two mappings differ key by key: a changed leaf, an added leaf and each
    /// leaf of a removed section give their dotted key path.
    @Test func eachLeafThatDiffersHasItsKeyPath() {
        let after: YAMLValue = .dictionary([
            "compaction": .dictionary(["trigger": .double(0.8), "hardCeiling": .int(9)])
        ])

        let ids = SettingsTreeDifference.ids(from: Self.before, to: after)

        #expect(ids == ChangedIDs(added: ["compaction.hardCeiling"], changed: ["compaction.trigger"], removed: ["tools.web.apiKeys.tavily"]))
    }

    /// A list is one leaf: a list that differs in one item changes the key
    /// of the list.
    @Test func aListIsOneLeaf() {
        let old: YAMLValue = .dictionary(["tools": .dictionary(["mcp": .array([.string("a")])])])
        let new: YAMLValue = .dictionary(["tools": .dictionary(["mcp": .array([.string("a"), .string("b")])])])

        #expect(SettingsTreeDifference.ids(from: old, to: new) == ChangedIDs(changed: ["tools.mcp"]))
    }

    /// The `null` root of a level with no file has no key, thus a first file
    /// adds each of its leaves, and the same tree has no difference.
    @Test func aNullRootHasNoKey() {
        #expect(
            SettingsTreeDifference.ids(from: .null, to: Self.before)
                == ChangedIDs(added: ["compaction.trigger", "tools.web.apiKeys.tavily"]))
        #expect(SettingsTreeDifference.ids(from: Self.before, to: Self.before) == ChangedIDs())
    }
}
