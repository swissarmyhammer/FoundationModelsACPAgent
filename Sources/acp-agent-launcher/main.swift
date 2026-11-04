import acp_agent

// The entry point of the shipped `acp-agent` binary: the command tree over
// the live model loader.
await AcpAgentCommand.launch(modelChoice: .live)
