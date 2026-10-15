import FoundationModelsExtras

// `RoutedSessionActor.runPlane` is internal. A debug build compiles Router
// with testing enabled, so the test reads it this way.
@testable import FoundationModelsRouter

/// The user presence that the run plane of `session` got from its
/// `SessionConfiguration` (elicitation-plan tasks 6 and 7).
///
/// - Parameter session: The Router session.
/// - Returns: The presence, or `nil` when `session` is not the Router
///   session actor.
func runPlanePresence(of session: any RoutedSession) -> UserPresence? {
    (session as? RoutedSessionActor)?.runPlane.userPresence
}
