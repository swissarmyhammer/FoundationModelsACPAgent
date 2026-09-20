import FoundationModels
import FoundationModelsRouter

/// The compaction rule that keeps each loaded skill in the transcript.
///
/// A `use skill` call of the standalone `skills` tool returns the body of a
/// skill: the procedure that the model must follow for the rest of the
/// session. Router's compaction elides old tool outputs and drops old turns,
/// so without this rule a fold removes the procedure, and the model goes on
/// with no procedure and no visible error. The Agent Skills standard calls
/// skill instructions "durable behavioral guidance" and asks a host to exempt
/// them from pruning.
///
/// The rule reads the call, not the output text: a loaded skill carries no
/// marker, and none is added. A call is protected when its tool is `skills`
/// and its `op` names the `use` verb on the `skill` noun, with the verb
/// aliases that the skills tool itself accepts (`call`, `invoke`, `get`).
/// Every other output of the `skills` tool, such as a search result, is not
/// protected.
enum SkillOutputProtection {
    /// The name of the standalone skills tool.
    static let skillsToolName = "skills"

    /// The name of the fused operation property of a `skills` call.
    static let operationProperty = "op"

    /// The noun of the operation that loads a skill.
    static let skillNoun = "skill"

    /// The verbs that the skills tool resolves to its `use` operation:
    /// `use` itself and the aliases of its resolver.
    static let useVerbs: Set<String> = ["use", "call", "invoke", "get"]

    /// The rule Router applies to each tool output at a compaction.
    static let rule: ToolOutputProtection = { call, _ in
        isSkillLoad(call)
    }

    /// Whether `call` loads a skill.
    ///
    /// - Parameter call: The tool call that made an output.
    /// - Returns: `true` for a `skills` call whose `op` is the `use skill`
    ///   operation or one of its verb aliases.
    static func isSkillLoad(_ call: Transcript.ToolCall) -> Bool {
        guard call.toolName == skillsToolName,
            let operation = try? call.arguments.value(String.self, forProperty: operationProperty)
        else {
            return false
        }
        let words = operation.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.count == 2 else {
            return false
        }
        return useVerbs.contains(words[0]) && words[1] == skillNoun
    }
}
