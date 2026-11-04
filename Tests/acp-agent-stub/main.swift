import Foundation
import acp_agent

// The entry point of the test-only `acp-agent-stub` binary: the command tree
// of `acp-agent` over the deterministic stub model of the library.
//
// The two paths below carry configuration into a stub that always stands in
// place of the live loader: the named pipe that holds a prompt open until a
// test lets a chunk go, and the JSON script that a session plays. Neither
// variable chooses the model; this binary is the choice. A child that this
// process spawns (`run --out-of-process` starts `acp-agent-stub acp`)
// inherits both, so a stub stands two process boundaries away too.

/// The environment variable with the path of the chunk gate: a named pipe
/// that the stub reads one byte from before each chunk of the echoed prompt.
let chunkGateVariable = "ACP_AGENT_STUB_CHUNK_GATE"

/// The environment variable with the path of the JSON script file of the
/// stub model (`ScriptedStubScript`).
let scriptVariable = "ACP_AGENT_STUB_SCRIPT"

/// Reads the path in `name`, or `nil` for an absent or empty variable.
///
/// - Parameter name: The environment variable to read.
/// - Returns: The path, or `nil` when the variable gates or scripts nothing.
func pathInEnvironment(named name: String) -> String? {
  guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty else {
    return nil
  }
  return path
}

await AcpAgentCommand.launch(
  modelChoice: .stub(
    chunkGate: pathInEnvironment(named: chunkGateVariable),
    script: pathInEnvironment(named: scriptVariable)))
