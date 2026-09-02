import Foundation
import FoundationModelsACP
import FoundationModelsACPClient
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// Dispatch at the prompt owner (plan.md §14.3, §14.4): the three body
/// kinds, the unknown-command refusal, the attachment rules, and the
/// `available_commands_update` publication.
struct CommandDispatchTests {
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
                NewSessionRequest(cwd: try #require(AbsolutePath(rawValue: cwd.path))))
            let collector = try #require(harness.collector)
            return Fixture(
                harness: harness, collector: collector, sessionId: response.sessionId, cwd: cwd)
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

    /// The `agent_message_chunk` texts in the collected sequence.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The chunk texts, in arrival order.
    private static func chunkTexts(in updates: [UpdateSessionNotification]) -> [String] {
        updates.compactMap { notification in
            guard case .agentMessageChunk(let chunk) = notification.update,
                case .text(let content) = chunk.content
            else {
                return nil
            }
            return content.text
        }
    }

    /// Whether the collected sequence holds any turn update: a state
    /// update, a user-message echo, or an agent-message chunk.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: `true` when a turn update is present.
    private static func holdsATurnUpdate(in updates: [UpdateSessionNotification]) -> Bool {
        updates.contains { notification in
            switch notification.update {
            case .stateUpdate, .userMessage, .agentMessageChunk, .agentMessage:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Unknown commands (plan.md §14.3)

    /// A `/nosuchcmd` prompt gives an error that names the nearest
    /// command, and the model backend is never invoked.
    @Test(.timeLimit(.minutes(1)))
    func anUnknownCommandRefusesWithANearMissAndNoModelTurn() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-unknown",
            providers: [
                StubCommandProvider(commandSet: [makeRenderedCommand(name: "deploy", prefix: "D ")])
            ])
        defer { Task { await fixture.close() } }

        do {
            _ = try await fixture.harness.agent.prompt(
                ScriptedTurnFixture.makePromptRequest(sessionId: fixture.sessionId, text: "/deployy now"))
            Issue.record("expected the unknown-command refusal")
        } catch let error as RequestError {
            #expect(error.code == .invalidParams)
            guard case .object(let fields) = try #require(error.data) else {
                Issue.record("expected object data, got \(String(describing: error.data))")
                return
            }
            // `deployy` is one edit from the provider's `deploy` and far from
            // every registered builtin, so the near miss is `deploy` alone.
            #expect(fields["command"] == .string("deployy"))
            #expect(fields["suggestions"] == .array([.string("deploy")]))
        }

        // No model turn ran: no state update, no echo, no message.
        #expect(!Self.holdsATurnUpdate(in: await fixture.collector.updates))
        #expect(await fixture.harness.agent.sessions[fixture.sessionId]?.availability == .idle)
    }

    // MARK: - The .rendered body (plan.md §14.2 gap 1)

    /// A `.rendered` provider body is called, and its output reaches
    /// the model turn.
    @Test(.timeLimit(.minutes(1)))
    func aRenderedBodyOutputReachesTheModelTurn() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-rendered",
            providers: [
                StubCommandProvider(commandSet: [
                    makeRenderedCommand(name: "render", prefix: "RENDERED ")
                ])
            ])
        defer { Task { await fixture.close() } }

        _ = try await fixture.harness.connection.prompt(
            ScriptedTurnFixture.makePromptRequest(sessionId: fixture.sessionId, text: "/render alpha"))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        #expect(Self.chunkTexts(in: updates).contains { $0.contains("RENDERED alpha") })
    }

    // MARK: - The skills path (plan.md §14.2)

    /// A real skill with a `$1` placeholder reaches the model with the
    /// second argument substituted, which proves the `registry.call`
    /// path ran all three render passes.
    @Test(.timeLimit(.minutes(1)))
    func aSkillCommandRunsThroughRegistryCall() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-skill",
            skillFiles: ["greet": greetSkillMarkdown])
        defer { Task { await fixture.close() } }

        _ = try await fixture.harness.connection.prompt(
            ScriptedTurnFixture.makePromptRequest(
                sessionId: fixture.sessionId, text: "/greet alpha beta"))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        #expect(Self.chunkTexts(in: updates).contains { $0.contains("Hello beta.") })
    }

    // MARK: - The .action body (plan.md §14.3)

    /// An `.action` command with an attached resource link is refused
    /// with a reason, and no model turn runs.
    @Test(.timeLimit(.minutes(1)))
    func anActionCommandWithAnAttachmentIsRefused() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-refused",
            providers: [
                StubCommandProvider(commandSet: [
                    makeActionCommand(name: "act", output: "ACTION OUTPUT")
                ])
            ])
        defer { Task { await fixture.close() } }

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
            guard case .object(let fields) = try #require(error.data) else {
                Issue.record("expected object data, got \(String(describing: error.data))")
                return
            }
            #expect(fields["command"] == .string("act"))
            #expect(fields["reason"] != nil)
        }

        #expect(!Self.holdsATurnUpdate(in: await fixture.collector.updates))
        #expect(await fixture.harness.agent.sessions[fixture.sessionId]?.availability == .idle)
    }

    /// An `.action` command streams its text with no model turn, and
    /// the turn ends idle with `end_turn`.
    @Test(.timeLimit(.minutes(1)))
    func anActionCommandStreamsWithNoModelTurn() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-action",
            providers: [
                StubCommandProvider(commandSet: [
                    makeActionCommand(name: "act", output: "ACTION OUTPUT")
                ])
            ])
        defer { Task { await fixture.close() } }

        _ = try await fixture.harness.connection.prompt(
            ScriptedTurnFixture.makePromptRequest(sessionId: fixture.sessionId, text: "/act"))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)

        let texts = Self.chunkTexts(in: updates)
        #expect(texts.contains("ACTION OUTPUT"))
        // The echo model would stream the prompt back. No chunk carries
        // it, so no model turn ran.
        #expect(!texts.contains { $0.contains("/act") })
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - The ACP surface (plan.md §14.4)

    /// The collector receives `available_commands_update` after
    /// `session/new`, and again after a skill file changes on disk.
    @Test(.timeLimit(.minutes(1)))
    func availableCommandsPublishAtSessionStartAndOnASkillChange() async throws {
        let fixture = try await Fixture.make(
            label: "CommandDispatchTests-publish",
            skillFiles: ["greet": greetSkillMarkdown])
        defer { Task { await fixture.close() } }

        _ = try await ScriptedTurnFixture.waitForUpdates(
            of: fixture.collector, toReach: "the session-start publication"
        ) { updates in
            updates.contains { Self.commandNames(in: $0)?.contains("greet") == true }
        }

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
        _ = try await ScriptedTurnFixture.waitForUpdates(
            of: fixture.collector, toReach: "the watched republication"
        ) { updates in
            updates.contains { Self.commandNames(in: $0)?.contains("farewell") == true }
        }
    }
}
