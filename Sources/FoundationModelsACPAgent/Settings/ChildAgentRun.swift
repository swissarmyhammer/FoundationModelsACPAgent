import FoundationModelsExtras

/// The test of a child agent run, and the refusals of the changes that a
/// child run cannot make (D193).
///
/// A child agent run shares the tools of its session, but the marketplaces
/// and the profiles are configuration of the user. The storage of each of
/// them refuses a change whose tool call runs in a session that has a parent
/// session. A root session and an app endpoint have no such tool context.
enum ChildAgentRun {
  /// The code of a refusal in the `errors` list of a GraphQL response.
  static let refusalCode = "CHILD_RUN"

  /// The text of the refusal of a profile change from a child run.
  static let profileRefusal =
    "A child agent run cannot select, save or delete a profile: the profiles are configuration of the "
    + "user. Read them with the models tool, and ask the user or the parent session to change them."

  /// Tells if the current tool call runs in a child agent run: its session
  /// has a parent session.
  ///
  /// - Returns: `true` in a child run.
  @Sendable static func isCurrent() -> Bool {
    ToolContext.current?.parentSessionID != nil
  }
}
