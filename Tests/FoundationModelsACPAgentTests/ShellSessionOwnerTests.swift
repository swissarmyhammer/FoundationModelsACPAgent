import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// Each shell command records the ACP session id of the session that ran it
/// (task ^v3xvh4t). A model slot switch makes a new Router session with a new
/// id over the same tools, and the shell still records the ACP id.
///
/// The proof drives the real agent over the scripted model: the scripted
/// model calls `runCode`, the snippet calls `tools.shell.execute`, and the
/// command runs under the real sandbox. No weights load and no network is
/// used.
@Suite(.closesHarnesses) struct ShellSessionOwnerTests {
    /// The marker of the prompt that runs the command.
    private static let runMarker = "Run the owner probe"

    /// The text the command writes, which the search of the store finds.
    private static let commandOutput = "owner-probe-output"

    /// The text of each pass that does not run the command.
    private static let reply = "the probe ran"

    /// The script of the proof: the prompt with the marker runs one shell
    /// command, and each other pass plays the reply and ends.
    ///
    /// - Returns: The script.
    /// - Throws: When the arguments of the `runCode` call cannot be encoded.
    private static func makeScript() throws -> [ScriptedPassStep] {
        let snippet = #"return await tools.shell.execute({ command: "echo \#(commandOutput)" });"#
        return [
            .onPrompt(containing: runMarker, play: try ScriptedPromptFixture.makeToolPromptScript(code: snippet)),
            .textDelta(reply),
            .endPass,
        ]
    }

    @Test func aCommandAfterAModelSlotSwitchRecordsTheACPSessionID() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: try Self.makeScript(), label: "ShellSessionOwnerTests-switch")
        _ = try await fixture.harness.connection.setSessionConfigOption(
            SetSessionConfigOptionRequest(
                configId: ConfigOptions.modelOptionId, sessionId: fixture.sessionId,
                value: .id(SessionConfigValueId(rawValue: ModelSlot.flash.rawValue))))
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.runMarker))
        _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)

        let entry = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
        let store = try #require(entry.surface.shellStoreLease).store
        let reader = try MultiTool.Builder().withShell(store: store).buildRegistry()
        let grep = try await ShellVerbSupport.grepHistory(in: reader, pattern: Self.commandOutput)
        let matches = try #require(grep["matches"] as? [[String: Any]])
        await fixture.close()

        #expect(entry.session.id.description != fixture.sessionId.rawValue)
        #expect(matches.map { $0["sessionID"] as? String } == [fixture.sessionId.rawValue])
    }
}
