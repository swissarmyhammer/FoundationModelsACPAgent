import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// Dispatch at the prompt owner: the three body kinds, the
/// unknown-command refusal, the attachment rules, and the
/// `available_commands_update` publication. A leading `/name` goes
/// through the registry before anything touches the session, so a slash
/// command never reaches the model as a prompt.
@Suite(.closesHarnesses) struct CommandDispatchTests {
    /// One wired dispatch fixture: an echo-model agent with stub
    /// command providers, a recording harness, an initialized wire, and
    /// one new session in `cwd`.
    ///
    /// The default stub model echoes the model prompt back, so the
    /// `agent_message_chunk` text IS the text that reached the model.
    private struct Fixture {
        /// The wired harness.
        let harness: AgentClientHarness

        /// The collector of the raw update sequence.
        let collector: UpdateCollector

        /// The id of the one open session.
        let sessionId: SessionId

        /// The session working directory.
        let cwd: URL

        /// The command names that the `session/new` response announced.
        let announcedCommandNames: [String]

        /// Closes the harness wire.
        func close() async {
            await harness.close()
        }

        /// Wires an echo-model agent with `providers` registered and
        /// the given skills written under `<cwd>/.skills/`, completes
        /// `initialize`, and opens one session.
        ///
        /// - Parameters:
        ///   - label: The directory label of the calling test.
        ///   - providers: The stub providers to register.
        ///   - skillFiles: The skills to write, id to `SKILL.md` content.
        /// - Returns: The fixture.
        /// - Throws: Whatever the construction or the handshake throws.
        static func make(
            label: String,
            providers: [any SlashCommandProviding] = [],
            skillFiles: [String: String] = [:]
        ) async throws -> Fixture {
            let cwd = makeResolvedDirectory(label: "\(label)-repo")
            let skillsRoot = cwd.appendingPathComponent(".skills", isDirectory: true)
            try FileManager.default.createDirectory(
                at: skillsRoot, withIntermediateDirectories: true)
            for (id, markdown) in skillFiles {
                try writeSkillFixture(id: id, markdown: markdown, under: skillsRoot)
            }
            let agent = try await makeStubAgent(
                name: AgentClientHarness.dotfolderName,
                cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
                userDirectory: makeResolvedDirectory(label: "\(label)-user"))
            await agent.registerCommandProviders(providers)
            let harness = await AgentClientHarness.makeRecording(agent: agent)
            _ = try await harness.connection.initialize(AgentClientHarness.makeInitializeRequest())
            let response = try await harness.connection.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: cwd.path)))
            let collector = try #require(harness.collector)
            return Fixture(
                harness: harness, collector: collector, sessionId: response.sessionId, cwd: cwd,
                announcedCommandNames: (response.availableCommands ?? []).map(\.name))
        }
    }

    /// The names in an `available_commands_update`, or `nil` when the
    /// notification is another kind.
    ///
    /// - Parameter notification: The recorded notification.
    /// - Returns: The command names, or `nil`.
    private static func commandNames(in notification: UpdateSessionNotification) -> [String]? {
        guard case .availableCommandsUpdate(let update) = notification.update else {
            return nil
        }
        return update.availableCommands.map(\.name)
    }

    /// Whether the collected sequence holds any prompt update: a state
    /// update, a user-message echo, or an agent-message chunk.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: `true` when a prompt update is present.
    private static func holdsAPromptUpdate(in updates: [UpdateSessionNotification]) -> Bool {
        updates.contains { notification in
            switch notification.update {
            case .stateUpdate, .userMessage, .agentMessageChunk, .agentMessage:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Unknown commands

    /// A `/nosuchcmd` prompt gives an error that names the nearest
    /// command, and the model backend is never invoked.
    @Test
    func anUnknownCommandRefusesWithANearMissAndNoModelPass() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-unknown",
            providers: [
                StubCommandProvider(commandSet: [makeRenderedCommand(name: "deploy", prefix: "D ")])
            ])

        do {
            _ = try await fixture.harness.agent.prompt(
                AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "/deployy now"))
            Issue.record("expected the unknown-command refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            let fields = try #require(
                jsonObject(of: error.data),
                "expected object data, got \(String(describing: error.data))")
            // `deployy` is one edit from the provider's `deploy` and far from
            // every registered builtin, so the near miss is `deploy` alone.
            #expect(fields["command"] == .string("deployy"))
            #expect(fields["suggestions"] == .array([.string("deploy")]))
        }

        // No model pass ran: no state update, no echo, no message.
        #expect(!Self.holdsAPromptUpdate(in: await fixture.collector.updates))
        #expect(await fixture.harness.agent.sessions[fixture.sessionId]?.availability == .idle)
        await fixture.close()
    }

    // MARK: - The .rendered body

    /// A `.rendered` provider body is called, and its output reaches
    /// the model pass. The provider renders, and the dispatcher gives the
    /// result to the model, as it does for `.prompt`.
    @Test
    func aRenderedBodyOutputReachesTheModelPass() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-rendered",
            providers: [
                StubCommandProvider(commandSet: [
                    makeRenderedCommand(name: "render", prefix: "RENDERED ")
                ])
            ])

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "/render alpha"))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()
        let texts = ScriptedPromptFixture.agentChunkTexts(in: updates)
        #expect(texts.contains { $0.contains("RENDERED alpha") })
    }

    // MARK: - The skills path

    /// A real skill with a `$1` placeholder reaches the model with the
    /// second argument substituted, which proves the `registry.call`
    /// path ran all three render passes. A skill command still carries a
    /// raw `.prompt(template:)` body, so the dispatcher sends skill
    /// commands through `registry.call(id:arguments:)` for full fidelity.
    @Test
    func aSkillCommandRunsThroughRegistryCall() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-skill",
            skillFiles: ["greet": greetSkillMarkdown])

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(
                sessionId: fixture.sessionId, text: "/greet alpha beta"))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()
        let texts = ScriptedPromptFixture.agentChunkTexts(in: updates)
        #expect(texts.contains { $0.contains("Hello beta.") })
    }

    // MARK: - The .action body

    /// An `.action` command with an attached resource link is refused
    /// with a reason, and no model pass runs.
    @Test
    func anActionCommandWithAnAttachmentIsRefused() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-refused",
            providers: [
                StubCommandProvider(commandSet: [
                    makeActionCommand(name: "act", output: "ACTION OUTPUT")
                ])
            ])

        let blocks: [ContentBlock] = [
            .text(TextContent(text: "/act")),
            .resourceLink(ResourceLink(name: "notes", uri: "file:///tmp/notes.txt")),
        ]
        do {
            _ = try await fixture.harness.agent.prompt(
                PromptRequest(prompt: blocks, sessionId: fixture.sessionId))
            Issue.record("expected the attachment refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            let fields = try #require(
                jsonObject(of: error.data),
                "expected object data, got \(String(describing: error.data))")
            #expect(fields["command"] == .string("act"))
            #expect(fields["reason"] != nil)
        }

        #expect(!Self.holdsAPromptUpdate(in: await fixture.collector.updates))
        #expect(await fixture.harness.agent.sessions[fixture.sessionId]?.availability == .idle)
        await fixture.close()
    }

    /// An `.action` command streams its text with no model pass, and
    /// the prompt ends idle with `end_turn`.
    @Test
    func anActionCommandStreamsWithNoModelPass() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-action",
            providers: [
                StubCommandProvider(commandSet: [
                    makeActionCommand(name: "act", output: "ACTION OUTPUT")
                ])
            ])

        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "/act"))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        let texts = ScriptedPromptFixture.agentChunkTexts(in: updates)
        #expect(texts.contains("ACTION OUTPUT"))
        // The echo model would stream the prompt back. No chunk carries
        // it, so no model pass ran.
        #expect(!texts.contains { $0.contains("/act") })
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    /// The response to a slash command names the user message of the
    /// command (ACP schema-v2.0.0-alpha.7): its `messageId` is the id of the
    /// one `user_message` echo that reaches the client.
    @Test
    func aSlashCommandResponseNamesTheEchoedUserMessage() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-message-id",
            providers: [
                StubCommandProvider(commandSet: [
                    makeActionCommand(name: "act", output: "ACTION OUTPUT")
                ])
            ])

        let response = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: "/act"))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.close()

        let echoIds = updates.compactMap { userMessageEcho(of: $0.update)?.messageId }
        #expect(echoIds == [response.messageId])
    }

    // MARK: - The ACP surface

    /// The `session/new` response holds the first command list (ACP
    /// schema-v2.0.0-alpha.7), so no `available_commands_update` repeats
    /// it. A skill file that changes on disk then publishes the new list.
    @Test
    func theNewSessionResponseHoldsTheCommandListAndASkillChangePublishesTheNext() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-publish",
            skillFiles: ["greet": greetSkillMarkdown])

        #expect(fixture.announcedCommandNames.contains("greet"))

        // A new skill file on the watched root republishes the set.
        try writeSkillFixture(
            id: "farewell",
            markdown: """
                ---
                name: farewell
                description: Says goodbye.
                ---
                Goodbye.
                """,
            under: fixture.cwd.appendingPathComponent(".skills", isDirectory: true))
        let updates = try await ScriptedPromptFixture.waitForUpdates(
            of: fixture.collector, toReach: "the watched republication"
        ) { updates in
            updates.contains { Self.commandNames(in: $0)?.contains("farewell") == true }
        }
        await fixture.close()
        // The first publication is the new list: none repeated the list of
        // the response.
        let publications = updates.compactMap(Self.commandNames(in:))
        #expect(publications.first?.contains("farewell") == true)
    }
}
