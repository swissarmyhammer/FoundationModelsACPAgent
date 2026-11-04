/// The model path a process of the CLI builds its agent over.
///
/// The choice is made by the executable that starts the CLI, and not by the
/// environment: the shipped `acp-agent` binary always chooses ``live``, and
/// the test-only `acp-agent-stub` binary chooses ``stub(chunkGate:script:)``.
/// So the shipped composition path has no test-mode switch.
public enum AgentModelChoice: Equatable, Sendable {
  /// The live loader, which loads the models of the profile.
  case live

  /// The deterministic stub model of the library (`ComposedAgent.ModelSource.stub`).
  ///
  /// - Parameters:
  ///   - chunkGate: The path of a named pipe that the stub reads one byte
  ///     from before each chunk of the echoed prompt, or `nil` for the
  ///     one-chunk echo. It holds a prompt open across a process boundary,
  ///     so a signal lands before the prompt ends, with no clock.
  ///   - script: The path of the JSON script file of the stub model
  ///     (`ScriptedStubScript`), or `nil` for the echo.
  case stub(chunkGate: String?, script: String?)
}
