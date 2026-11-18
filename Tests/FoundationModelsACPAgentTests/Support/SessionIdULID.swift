import FoundationModelsACP
import FoundationModelsRouter
import Testing

extension SessionId {
  /// The ULID of the wire session id. `AgentSessionLauncherTests` and
  /// `DirectoryMessageWireTests` give a wire session id to the session
  /// directory, which reads a ULID, so the conversion lives here one time.
  ///
  /// - Returns: The ULID. The test fails when the id is not a ULID.
  func ulid() throws -> ULID {
    try #require(ULID(ulidString: rawValue))
  }
}
