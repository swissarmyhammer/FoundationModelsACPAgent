import Foundation

/// The compiled-in section that gives the agent the name that the host
/// selected, for example `Testudo`.
///
/// ``InstructionsAssembler`` puts this section right after the
/// ``StyleInstructions`` text, only when the host gave a name
/// (``RoutedACPAgent/agentName``). An `Instructions.md` replaces only the
/// base prompt, thus it cannot replace this section. So the agent tells the
/// same name also when a person changes its instructions.
public enum AgentNameInstructions {
  /// The text of the section.
  ///
  /// - Parameter name: The name of the agent.
  /// - Returns: The section text.
  public static func text(name: String) -> String {
    """
    # Name

    - Your name is \(name).
    - When the user asks your name, say that your name is \(name).
    """
  }
}
