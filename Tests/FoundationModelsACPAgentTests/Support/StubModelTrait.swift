import Testing

@testable import acp_agent

/// The trait that makes the CLI composition of each test of a suite build
/// its agent over the deterministic stub model, with no gate and no script.
///
/// Give it to a suite with `@Suite(.stubModel)`. It binds
/// ``AgentComposition/modelChoice`` for the test and for each task that the
/// test starts, so a test composes the agent through the same path as the
/// test-only `acp-agent-stub` binary, and the shipped composition path reads
/// no environment variable.
struct StubModelTrait: SuiteTrait, TestTrait, TestScoping {
  /// The trait applies to each test of the suite.
  var isRecursive: Bool { true }

  /// Gives a scope to each test case only, and not to the suite.
  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    testCase == nil ? nil : self
  }

  /// Runs the test with the stub model as the model choice.
  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    try await AgentComposition.$modelChoice.withValue(.stub(chunkGate: nil, script: nil)) {
      try await function()
    }
  }
}

extension Trait where Self == StubModelTrait {
  /// The stub model for each test of the suite.
  static var stubModel: Self { Self() }
}
