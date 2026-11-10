/// The compiled-in style text that starts the instructions of each session
/// (ACPA-20, D153). The style is the same for each agent:
/// ``InstructionsAssembler`` puts the text before the base prompt (the
/// session agent, the `default` agent, an `Instructions.md`, or
/// ``BuiltinInstructions``) and before each `AGENTS.md` text. An
/// `Instructions.md` replaces only the base prompt, not this text.
///
/// The README links to this file as the one copy of the text, and
/// `DocumentationSyncTests` asserts the link cannot rot. The README does
/// not repeat the text.
///
/// Each sub-agent run starts with the same text:
/// `AgentsComposition.compose` gives it to the agent environment as the
/// instructions preamble. The type is public, so that a host can give the
/// same text to the runs of its own sub-agents.
public enum StyleInstructions {
  /// The style text.
  public static let text = """
    # Style

    - Write each answer in ASD-STE100 Simplified Technical English: short
      sentences, one instruction in each sentence, the active voice, and
      one meaning for each word.
    - Keep code, commands, file paths, identifiers and quoted text as they
      are.
    - Give the answer first. Do not write a preamble. Do not repeat the
      question. Do not give a summary that the user did not ask for.
    - Write a long answer only when the request needs it, for example a
      plan or a report.
    """
}
