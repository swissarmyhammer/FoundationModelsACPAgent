import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsACPClient
import FoundationModelsMultitool
import FoundationModelsRouter
import MCPTestServer
import Testing

@testable import FoundationModelsACPAgent

/// Tier 2 of the test ladder (plan.md §20.1): a real `ToolCatalog`, a
/// real `MultiTool` with the files and shell capabilities, a real
/// `RoutedACPAgent`, a real `session/new` on a temp directory, and a
/// scripted model, driven and asserted through `FoundationModelsACPClient`.
///
/// Each proof checks a fact that this agent owns: the composition of the
/// catalog, the projection of a tool call to the wire, the wire order, the
/// enable and disable rule, and the MCP mount. The confinement and the
/// sandbox rules belong to Multitool and to `SandboxComposition`, and the
/// suites of those rules prove them (`MultiRootConfinementTests`,
/// `SandboxCompositionTests`). The terminal projection has its own
/// synthetic suite (`TerminalStreamTests`).
///
/// Each script is `runCode`, then the end. No script waits for an async
/// tool result: a run that does not settle inside the inline grace of
/// `runCode` comes back as mail when it comes back.
///
/// The discipline is §20.1's: check the filesystem, never the
/// transcript. A "file written" claim is proven by reading the file
/// from disk.
@Suite struct TierTwoTests {
    // MARK: - Constants

    /// The prompt text of every scripted tool prompt.
    private static let promptText = "Run the scripted tool pass"

    /// The name of the code-mode session tool the scripts invoke.
    private static let runCodeToolName = "runCode"

    /// The SDK id of the first scripted tool call — the `runCode` call.
    private static let runCodeCallId = ScriptedSessionBackend.scriptedCallIdPrefix + "1"

    /// The marker of the files capability's in-band out-of-root
    /// correction (Multitool's `PathGuard` wording).
    private static let confinementRefusalMarker = "outside workspace boundaries"

    /// The whole opening of the out-of-root correction. The composition
    /// proof matches the opening, so the outcome label in front of it
    /// ties the correction to the read that answered it.
    private static let confinementRefusalOpening = "Path is " + confinementRefusalMarker

    /// The secret the confinement proofs plant outside the root set.
    /// It must never cross the wire.
    private static let outsideSecret = "TIER-TWO-OUTSIDE-SECRET-b2f4"

    /// The file the projection proof writes and reads back.
    private static let noteFileName = "tier-two-note.txt"

    /// The exact content the projection proof writes to disk.
    private static let noteContent = "tier two wrote this line"

    /// The project config of the note prompt: change recording enabled.
    ///
    /// The flag makes each mutating verb call attach its structured
    /// `FileChangeSet`, which is the only permitted source of
    /// `locations` (plan.md §11.5, §11.6). The builder default is off,
    /// so the proof asks for it the way a user does — in `config.yaml`.
    private static let recordsChangesConfigYAML = """
        tools:
          files:
            recordsChanges: true
        """

    /// The name the client-declared MCP test server mounts under —
    /// the noun of every `tools.<serverName>.<verb>` path.
    private static let mcpServerName = "alpha"

    /// The text the MCP proof sends through the echo tool.
    private static let echoPing = "tier two ping"

    /// The outcome label of the MCP proof's surface-listing test: does
    /// `help()` name the echo verb under the server's own noun?
    private static let mountedPathLabel = "mounted"

    /// The outcome label of the MCP proof's `mcp` segment test: does
    /// `help()` name the echo verb under an `mcp` noun as well?
    private static let prefixedPathLabel = "prefixed"

    /// The outcome label of the MCP proof's round trip — the text the
    /// real subprocess echoed back.
    private static let echoedAnswerLabel = "echoed"

    /// The text a JavaScript `true` becomes when the snippet joins it
    /// onto an outcome line.
    private static let snippetTrue = "true"

    /// The text a JavaScript `false` becomes on an outcome line.
    private static let snippetFalse = "false"

    /// The verb paths of the two locally composed capabilities.
    private static let readVerbPath = "files.read"

    /// The shell execute verb path.
    private static let executeVerbPath = "shell.execute"

    /// The `journalOp` of the read verb — "verb noun" (Multitool's
    /// `APISurface.Entry`).
    private static let readJournalOp = "read files"

    /// The `journalOp` of the execute verb.
    private static let executeJournalOp = "execute shell"

    /// The file the composition proof plants under the session's
    /// additional root. A read of it answers content only when the built
    /// verbs took their root set from `cwd` plus `additionalDirectories`.
    private static let additionalRootFileName = "in-the-additional-root.txt"

    /// The exact content of the additional root's file.
    private static let additionalRootContent = "tier two reached the additional root"

    /// The file the composition proof asks the read-only session to
    /// write. It must never reach the disk.
    private static let refusedWriteFileName = "composition-refused-write.txt"

    /// The content the refused write would have carried.
    private static let refusedWriteContent = "tier two must never write this line"

    /// The project config of the composition proof's session: the files
    /// section is read-only, so every mutating verb refuses in band
    /// while the reading verbs stand.
    private static let readOnlyFilesConfigYAML = """
        tools:
          files:
            readOnly: true
        """

    /// The marker of the files capability's in-band read-only
    /// correction (Multitool's `Write` wording).
    private static let readOnlyRefusalMarker =
        "The session is read-only, so the `write` verb cannot change files."

    /// The label of each outcome line the composition snippet reports
    /// for the read under the additional root.
    private static let insideReadLabel = "inside"

    /// The outcome label of the read outside the root set.
    private static let outsideReadLabel = "outside"

    /// The outcome label of the write on the read-only session.
    private static let refusedWriteLabel = "write"

    /// The outcome label of the `searchTools` answer.
    private static let searchLabel = "search"

    /// How many characters of the `searchTools` answer the composition
    /// snippet reports.
    ///
    /// The whole answer carries each selected entry's documentation
    /// block, which overruns the tool-output cap and truncates the
    /// outcome lines with it. The opening carries the header and the
    /// first entry's verb path, which is the part the proof reads.
    private static let searchAnswerReportLength = 200

    /// The task the composition proof gives `searchTools`. The stub
    /// librarian's recorded prompt must carry it, which is what ties the
    /// recording to this call.
    private static let librarianTask = "read one text file from the workspace"

    /// The selection the stub librarian answers, in the shape
    /// `SelectionTier` decodes. It names the shell execute verb, which
    /// is not the verb ``librarianTask`` describes, so an answer that
    /// reports that verb can only have come from the librarian slot.
    private static let librarianSelectionJSON = #"{"ids":["\#(executeVerbPath)"]}"#

    // MARK: - Script builders

    /// The `runCode` arguments JSON for `code`, encoded so the snippet
    /// text is escaped correctly.
    ///
    /// - Parameter code: The snippet to run.
    /// - Returns: The arguments JSON.
    /// - Throws: The encoding error.
    private static func runCodeArgumentsJSON(code: String) throws -> String {
        try encodedText(of: ["code": code])
    }

    /// A JSON string literal of `text`, for embedding a path or a
    /// command into a snippet.
    ///
    /// - Parameter text: The text to quote.
    /// - Returns: The quoted literal, double quotes included.
    /// - Throws: The encoding error.
    private static func jsonStringLiteral(text: String) throws -> String {
        try encodedText(of: text)
    }

    /// The script of one tool pass: `runCode` with `code`, then the end.
    ///
    /// The snippets here finish inside the inline settle grace of
    /// `runCode`, so the `runCode` call answers the result itself. A run
    /// that takes longer comes back as mail when it comes back, and no
    /// proof here scripts a step that waits for it.
    ///
    /// - Parameter code: The snippet the prompt runs.
    /// - Returns: The script.
    /// - Throws: The arguments-encoding error.
    private static func makeToolPromptScript(code: String) throws -> [ScriptedPassStep] {
        [
            .toolCall(name: runCodeToolName, argumentsJSON: try runCodeArgumentsJSON(code: code)),
            .endPass,
        ]
    }

    /// The write-then-read-back snippet of the projection proofs. Each
    /// step returns its in-band correction when one arrives, so a
    /// failure names itself in the answer.
    private static var noteCode: String {
        """
        const written = await tools.files.write({ path: "\(noteFileName)", content: "\(noteContent)" });
        if (written.correction) { return written.correction; }
        const read = await tools.files.read({ path: "\(noteFileName)", format: "plain" });
        if (read.correction) { return read.correction; }
        return read.lines;
        """
    }

    /// The snippet of the composition proof: a read under the session's
    /// additional root, a read outside the root set, a write on the
    /// read-only session, and one `searchTools` call that runs on the
    /// profile's flash slot.
    ///
    /// Each step reports its own outcome on a labeled line, so one
    /// assertion reads one fact and a failure names the step it came
    /// from.
    ///
    /// - Parameters:
    ///   - insidePath: The file under the additional root to read.
    ///   - outsidePath: The file outside the root set to read.
    /// - Returns: The snippet.
    /// - Throws: The path-quoting error.
    private static func compositionCode(
        insidePath: String, outsidePath: String
    ) throws -> String {
        """
        const inside = await tools.files.read({ path: \(try jsonStringLiteral(text: insidePath)), format: "plain" });
        const outside = await tools.files.read({ path: \(try jsonStringLiteral(text: outsidePath)), format: "plain" });
        const written = await tools.files.write({ path: "\(refusedWriteFileName)", content: "\(refusedWriteContent)" });
        const found = await tools.searchTools({ task: "\(librarianTask)" });
        return [
            "\(insideReadLabel)=" + (inside.correction ? inside.correction : inside.lines.join("")),
            "\(outsideReadLabel)=" + (outside.correction ? outside.correction : "the read answered content"),
            "\(refusedWriteLabel)=" + (written.correction ? written.correction : "the write changed the file"),
            "\(searchLabel)=" + found.slice(0, \(searchAnswerReportLength))
        ].join("\\n");
        """
    }

    /// The snippet of the MCP proof: one `help()` listing reduced to
    /// the two path answers, and one echo call through the real
    /// subprocess.
    ///
    /// The listing becomes two booleans, so the mounted-path lines
    /// carry no verb text and the echoed line carries no path. A
    /// reader of one line therefore cannot be answered by the other
    /// line's source.
    ///
    /// - Parameters:
    ///   - echoPath: The verb path the server's own noun gives.
    ///   - prefixedPath: The verb path an `mcp` noun would give.
    /// - Returns: The snippet.
    /// - Throws: The path-quoting error.
    private static func mcpCode(echoPath: String, prefixedPath: String) throws -> String {
        """
        const listing = help();
        const answer = await tools.\(echoPath)({ \(ScriptedServer.echoTextArgument): "\(echoPing)" });
        return [
            "\(mountedPathLabel)=" + (listing.indexOf(\(try jsonStringLiteral(text: echoPath))) >= 0),
            "\(prefixedPathLabel)=" + (listing.indexOf(\(try jsonStringLiteral(text: prefixedPath))) >= 0),
            "\(echoedAnswerLabel)=" + answer
        ].join("\\n");
        """
    }

    /// One labeled outcome line of ``compositionCode(insidePath:outsidePath:)``.
    ///
    /// - Parameters:
    ///   - label: The step's outcome label.
    ///   - value: The value the step is expected to report.
    /// - Returns: The line the snippet emits for that step.
    private static func outcomeLine(label: String, value: String) -> String {
        "\(label)=\(value)"
    }

    // MARK: - Prompt driver

    /// Wires the fixture, prompts one scripted tool prompt, waits for
    /// the idle terminator, and flushes the coalescing buffer.
    ///
    /// - Parameters:
    ///   - code: The snippet the pass runs.
    ///   - label: The directory label of the calling proof.
    ///   - workingDirectory: The pre-made session working directory,
    ///     or `nil` to let the fixture make one.
    ///   - projectConfigYAML: The project `config.yaml`, or `nil`.
    ///   - mcpServers: The client's per-session MCP servers, or `nil`.
    ///   - additionalDirectories: The `session/new` additional roots,
    ///     or `nil` for none.
    ///   - flashContainer: The resident model the flash slot loads, or
    ///     `nil` to let every slot play the prompt script. The
    ///     composition proof passes a recording librarian here, because
    ///     `ToolCatalog.sessionSurface` hands `profile.flash` to
    ///     `searchTools`.
    ///   - tapsWire: Whether the harness records the raw wire lines.
    ///     Only the prompt-order proof reads them.
    /// - Returns: The fixture and the collected sequence at idle.
    /// - Throws: Whatever the wiring or the prompt throws.
    private static func runToolPrompt(
        code: String,
        label: String,
        workingDirectory: URL? = nil,
        projectConfigYAML: String? = nil,
        mcpServers: [FoundationModelsACP.MCPServer]? = nil,
        additionalDirectories: [AbsolutePath]? = nil,
        flashContainer: (any LoadedLLMContainer)? = nil,
        tapsWire: Bool = false
    ) async throws -> (fixture: ScriptedPromptFixture, updates: [UpdateSessionNotification]) {
        let script = try makeToolPromptScript(code: code)
        var loader = makeScriptedModelLoader(script: script)
        if let flashContainer {
            let scriptedContainer = loader.makeLLMContainer
            loader.makeLLMContainer = { slot in
                slot == .flash ? flashContainer : scriptedContainer(slot)
            }
        }
        let fixture = try await ScriptedPromptFixture.make(
            loader: loader,
            label: label,
            workingDirectory: workingDirectory,
            projectConfigYAML: projectConfigYAML,
            mcpServers: mcpServers,
            additionalDirectories: additionalDirectories,
            tapsWire: tapsWire)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
        let updates = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
        await fixture.harness.flushPendingChunks()
        return (fixture, updates)
    }

    /// Runs the shared write-then-read-back note prompt, with change
    /// recording on.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling proof.
    ///   - tapsWire: Whether the harness records the raw wire lines.
    /// - Returns: The fixture and the collected sequence at idle.
    /// - Throws: Whatever the wiring or the prompt throws.
    private static func runNotePrompt(
        label: String, tapsWire: Bool = false
    ) async throws -> (fixture: ScriptedPromptFixture, updates: [UpdateSessionNotification]) {
        try await runToolPrompt(
            code: noteCode,
            label: label,
            projectConfigYAML: recordsChangesConfigYAML,
            tapsWire: tapsWire)
    }

    // MARK: - Readers

    /// Every `tool_call_update` for `id`, in arrival order.
    ///
    /// - Parameters:
    ///   - updates: The collected sequence.
    ///   - id: The `toolCallId` to keep.
    /// - Returns: The matching updates.
    private static func toolCallUpdates(
        in updates: [UpdateSessionNotification], for id: String
    ) -> [ToolCallUpdate] {
        updates.compactMap { notification in
            guard case .toolCallUpdate(let update) = notification.update,
                update.toolCallId.rawValue == id
            else { return nil }
            return update
        }
    }

    /// The statuses the updates carry, in order, skipping `unchanged`.
    ///
    /// - Parameter updates: The tool-call updates to read.
    /// - Returns: The carried statuses.
    private static func statuses(
        of updates: [ToolCallUpdate]
    ) -> [FoundationModelsACP.ToolCallStatus] {
        updates.compactMap { update in
            guard case .value(let status) = update.status else { return nil }
            return status
        }
    }

    /// The paths of every filled `locations` array in the sequence, in
    /// arrival order.
    ///
    /// - Parameter updates: The collected sequence.
    /// - Returns: The reported location paths.
    private static func locationPaths(in updates: [UpdateSessionNotification]) -> [String] {
        updates.flatMap { notification -> [String] in
            guard case .toolCallUpdate(let update) = notification.update,
                case .value(let locations) = update.locations
            else { return [] }
            return locations.map(\.path.rawValue)
        }
    }

    /// The JSON text of one encodable wire value, for a contains
    /// assertion over everything the value carries.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON text.
    /// - Throws: The encoding error.
    private static func encodedText(of value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// The JSON text of one patch field's value, or the empty string
    /// when the field carries none.
    ///
    /// - Parameter field: The field to read.
    /// - Returns: The JSON text of the carried value.
    /// - Throws: The encoding error.
    private static func patchText<Value>(of field: PatchField<Value>) throws -> String {
        guard case .value(let value) = field else { return "" }
        return try encodedText(of: value)
    }

    /// The JSON text of one update's ANSWER — its `rawOutput` and its
    /// `content`, never its `rawInput`.
    ///
    /// The `runCode` call's `rawInput` carries the snippet source, and
    /// a snippet names the verbs it calls and the text it sends. A
    /// reader that took the whole update would therefore find an answer
    /// on the call that ASKED as well as on the call that ANSWERED.
    ///
    /// - Parameter update: The update to read.
    /// - Returns: The joined JSON text of the answering fields.
    /// - Throws: The encoding error.
    private static func answerText(of update: ToolCallUpdate) throws -> String {
        try patchText(of: update.rawOutput) + patchText(of: update.content)
    }

    /// The `toolCallId` of every call whose answer carries `text`.
    ///
    /// - Parameters:
    ///   - text: The text to look for.
    ///   - updates: The collected sequence.
    /// - Returns: The ids, without repeats.
    /// - Throws: The encoding error.
    private static func toolCallIdsAnswering(
        text: String, in updates: [UpdateSessionNotification]
    ) throws -> Set<String> {
        let ids = try updates.compactMap { notification -> String? in
            guard case .toolCallUpdate(let update) = notification.update else { return nil }
            return try answerText(of: update).contains(text)
                ? update.toolCallId.rawValue : nil
        }
        return Set(ids)
    }

    /// The joined ANSWER text of the `runCode` call, which carries the
    /// snippet's own result.
    ///
    /// It reads each update through ``answerText(of:)``, thus it carries the
    /// answering fields alone and never the `rawInput` that holds the
    /// snippet source.
    ///
    /// - Parameter updates: The collected sequence.
    /// - Returns: The joined answer text.
    /// - Throws: The encoding error.
    private static func snippetAnswerText(
        in updates: [UpdateSessionNotification]
    ) throws -> String {
        try answerText(ofCall: runCodeCallId, in: updates)
    }

    /// The joined ANSWER text of every update of one call of the prompt.
    ///
    /// - Parameters:
    ///   - id: The `toolCallId` to read.
    ///   - updates: The collected sequence.
    /// - Returns: The call's joined answer text.
    /// - Throws: The encoding error.
    private static func answerText(
        ofCall id: String, in updates: [UpdateSessionNotification]
    ) throws -> String {
        try toolCallUpdates(in: updates, for: id)
            .map { try answerText(of: $0) }
            .joined()
    }

    /// The JSON text of the whole collected sequence — the wire as one
    /// searchable string.
    ///
    /// - Parameter updates: The collected sequence.
    /// - Returns: The joined JSON text.
    /// - Throws: The encoding error.
    private static func encodedWireText(updates: [UpdateSessionNotification]) throws -> String {
        try updates.map { try encodedText(of: $0) }.joined(separator: "\n")
    }

    /// The accumulated tool call `id` in the session's observable
    /// state — the primary assertion surface (plan.md §20.1).
    ///
    /// - Parameters:
    ///   - fixture: The wired fixture.
    ///   - id: The `toolCallId` to read.
    /// - Returns: The accumulated update.
    /// - Throws: When the session or the call is absent.
    @MainActor
    private static func accumulatedToolCall(
        of fixture: ScriptedPromptFixture, id: String
    ) throws -> ToolCallUpdate {
        let state = try #require(fixture.harness.client.sessions[fixture.sessionId])
        return try #require(state.toolCalls[ToolCallId(rawValue: id)])
    }

    /// The `sessionUpdate` discriminator of the prompt echo, which is
    /// both the order marker and the value the wire carries.
    private static let userMessageMarker = "user_message"

    /// The order marker of one notification, for the §8.1 order proof:
    /// the echo, the running and idle states, and the tool updates.
    /// Every other update kind is not part of the ordered claim.
    ///
    /// - Parameter notification: The notification to classify.
    /// - Returns: The marker, or `nil` when the update is not ordered.
    private static func orderMarker(of notification: UpdateSessionNotification) -> String? {
        switch notification.update {
        case .userMessage: userMessageMarker
        case .stateUpdate(.running): "running"
        case .stateUpdate(.idle): "idle"
        case .toolCallUpdate: "tool_call_update"
        default: nil
        }
    }

    /// The top-level JSON object of one recorded wire line.
    ///
    /// - Parameter line: The framed line the agent sent.
    /// - Returns: The decoded object, or `nil` when the line is not one.
    private static func decodedObject(of line: String) -> [String: Any]? {
        let decoded = try? JSONSerialization.jsonObject(with: Data(line.utf8))
        return decoded as? [String: Any]
    }

    /// The `messageId` key of a `session/prompt` result and of a
    /// `user_message` update.
    private static let messageIdKey = "messageId"

    /// The index of the acknowledgement of `session/prompt` in the
    /// recorded wire lines, and the user-message id that it names.
    ///
    /// `PromptResponse` holds the required `messageId` and one optional
    /// `_meta` (ACP schema-v2.0.0-alpha.7), so the acknowledgement encodes
    /// as a result object with the `messageId` key alone. `initialize` and
    /// `session/new` each answer other keys, so this result names the
    /// prompt acknowledgement alone.
    ///
    /// - Parameter lines: The recorded wire lines, in wire order.
    /// - Returns: The index and the id, or `nil` when no such line arrived.
    private static func acknowledgement(in lines: [String]) -> (index: Int, messageId: String)? {
        for (index, line) in lines.enumerated() {
            guard let result = decodedObject(of: line)?["result"] as? [String: Any],
                result.count == 1, let messageId = result[messageIdKey] as? String
            else { continue }
            return (index, messageId)
        }
        return nil
    }

    /// The index of the first `user_message` notification in the
    /// recorded wire lines, and its `messageId`.
    ///
    /// - Parameter lines: The recorded wire lines, in wire order.
    /// - Returns: The index and the id, or `nil` when no echo arrived.
    private static func userMessage(in lines: [String]) -> (index: Int, messageId: String?)? {
        for (index, line) in lines.enumerated() {
            guard let params = decodedObject(of: line)?["params"] as? [String: Any],
                let update = params["update"] as? [String: Any],
                update["sessionUpdate"] as? String == userMessageMarker
            else { continue }
            return (index, update[messageIdKey] as? String)
        }
        return nil
    }

    // MARK: - Proof 1: composition

    /// `ToolCatalog` constructs each tool with the `CatalogContext` the
    /// session was composed from (plan.md §20.1 proof 1).
    ///
    /// The NAMES come from the built `APISurface`: the files and shell
    /// verbs mount under their nouns with the "verb noun" journal ops,
    /// and a configured MCP server mounts under its own name —
    /// `tools.<serverName>.<verb>`, with no `mcp` segment.
    ///
    /// The three context facts come from the client end, through one
    /// scripted tool prompt:
    ///
    /// - **The root set.** The session opens with an additional root. A
    ///   read under that root answers the planted content, and a read
    ///   outside the union of the cwd and that root refuses in band, so
    ///   the built verbs confine to `cwd` plus `additionalDirectories`.
    /// - **The decoded config section.** The project config sets
    ///   `tools.files.readOnly`. The write refuses in band with the
    ///   capability's read-only correction, and nothing lands on disk.
    /// - **The resolved profile.** The flash slot loads a recording stub
    ///   librarian that answers one selection. The prompt's `searchTools`
    ///   call records the selection prompt on that slot, and the answer
    ///   reports the verb the librarian selected.
    @Test(.timeLimit(.minutes(1)))
    func theCatalogComposesTheSurfaceFromTheLoadedConfiguration() async throws {
        let cwd = makeResolvedDirectory(label: "TierTwoTests-composition-repo")
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        try ScriptedPromptFixture.writeProjectConfig(
            yaml: """
            tools:
              mcp:
                - name: \(Self.mcpServerName)
                  command: \(serverCommand)
                  args: ["\(ServerMode.flagName)", "\(ServerMode.echo.rawValue)"]
            """,
            under: cwd)
        let loaded = try ConfigurationLoader(
            name: try DotfolderName(AgentClientHarness.dotfolderName),
            workingDirectory: cwd,
            userDirectory: makeResolvedDirectory(label: "TierTwoTests-composition-user"),
            environment: [:]
        ).load()
        let context = CatalogContext(
            workingDirectory: cwd,
            configuration: loaded.configuration,
            profile: try await makeStubProfile(
                cacheDirectory: makeResolvedDirectory(label: "TierTwoTests-composition-cache")))

        let built = try await ToolCatalog.makeRegistry(context: context)
        let entries = built.registry.surface.entries
        await built.pool.shutdownAll()

        let paths = entries.map(\.path)
        #expect(paths.contains(Self.readVerbPath))
        #expect(paths.contains(Self.executeVerbPath))
        let echoPath = "\(Self.mcpServerName).\(ScriptedServer.echoToolName)"
        #expect(paths.contains(echoPath))
        #expect(!paths.contains { $0.split(separator: ".").contains("mcp") })
        #expect(
            entries.first { $0.path == Self.readVerbPath }?.journalOp == Self.readJournalOp)
        #expect(
            entries.first { $0.path == Self.executeVerbPath }?.journalOp
                == Self.executeJournalOp)
        #expect(entries.first { $0.path == echoPath }?.group == Self.mcpServerName)

        try await Self.assertTheContextReachedTheBuiltTools()
    }

    /// Drives the wire half of proof 1: one scripted tool prompt on a
    /// session that carries an additional root, a read-only `files`
    /// section, and a recording librarian on the flash slot.
    ///
    /// The three `CatalogContext` facts are read from what the built
    /// tools did, never from the surface names.
    ///
    /// - Throws: Whatever the wiring, the prompt or the waits throw.
    private static func assertTheContextReachedTheBuiltTools() async throws {
        let additionalRoot = makeResolvedDirectory(label: "TierTwoTests-composition-extra")
        let insideFile = additionalRoot.appendingPathComponent(additionalRootFileName)
        try additionalRootContent.write(to: insideFile, atomically: true, encoding: .utf8)
        let outsideFile = makeResolvedDirectory(label: "TierTwoTests-composition-outside")
            .appendingPathComponent("secret.txt")
        try outsideSecret.write(to: outsideFile, atomically: true, encoding: .utf8)
        let librarianRecorder = PromptRecorder()

        let (fixture, updates) = try await runToolPrompt(
            code: try compositionCode(
                insidePath: insideFile.path, outsidePath: outsideFile.path),
            label: "TierTwoTests-composition-session",
            projectConfigYAML: readOnlyFilesConfigYAML,
            additionalDirectories: [AbsolutePath(rawValue: additionalRoot.path)],
            flashContainer: ScriptedLLMContainer(
                script: [.textDelta(librarianSelectionJSON), .endPass],
                recorder: librarianRecorder))
        let answerText = try snippetAnswerText(in: updates)
        let librarianPrompts = await librarianRecorder.prompts
        let refusedWrite = fixture.cwd.appendingPathComponent(refusedWriteFileName)
        await fixture.close()

        // The root set is the cwd plus `additionalDirectories`: the read
        // under the additional root answers content, and the read
        // outside the union answers the confinement correction.
        #expect(
            answerText.contains(
                outcomeLine(label: insideReadLabel, value: additionalRootContent)))
        #expect(
            answerText.contains(
                outcomeLine(label: outsideReadLabel, value: confinementRefusalOpening)))

        // The decoded `files` section reached the built verbs: the write
        // answers the read-only correction, and the disk is the truth
        // that nothing was written (plan.md §20.1).
        #expect(
            answerText.contains(
                outcomeLine(label: refusedWriteLabel, value: readOnlyRefusalMarker)))
        #expect(!FileManager.default.fileExists(atPath: refusedWrite.path))

        // The resolved profile reached the librarian slot: the flash
        // slot's model answered the selection call for this task, and
        // `searchTools` reports the verb that answer named.
        #expect(librarianPrompts.contains { $0.contains(librarianTask) })
        #expect(answerText.contains(executeVerbPath))
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - Proof 3: projection fidelity

    /// A real tool call becomes a correct `tool_call_update` upsert:
    /// one stable `toolCallId` from creation to completion, the title
    /// on the first report, `in_progress` before `completed`,
    /// `rawInput` carrying the call's real arguments, and `rawOutput`
    /// carrying each call's real answer — read from
    /// `ACPSessionState.toolCalls`. The file the snippet claims to
    /// have written is read back from disk, never from the transcript.
    ///
    /// The snippet settles inside the inline grace of `runCode`, so the
    /// `runCode` call's own answer carries the written line.
    @Test(.timeLimit(.minutes(1)))
    func aRealToolCallProjectsAStableUpsertLifecycle() async throws {
        let (fixture, updates) = try await Self.runNotePrompt(label: "TierTwoTests-projection")
        let runCodeUpdates = Self.toolCallUpdates(in: updates, for: Self.runCodeCallId)
        let accumulated = try await Self.accumulatedToolCall(of: fixture, id: Self.runCodeCallId)
        let noteURL = fixture.cwd.appendingPathComponent(Self.noteFileName)
        let onDisk = try textOnDisk(at: noteURL)
        await fixture.close()

        // The disk is the truth (plan.md §20.1).
        #expect(onDisk == Self.noteContent)

        // The written path rides `locations`, read from the attached
        // structured record and never from a rendered string
        // (plan.md §11.5, §11.6).
        #expect(Self.locationPaths(in: updates).contains(noteURL.path))

        // The first report creates the call: title and in_progress.
        let first = try #require(runCodeUpdates.first)
        #expect(first.title == .value(Self.runCodeToolName))
        #expect(first.status == .value(.inProgress))

        // The lifecycle: in_progress strictly before completed.
        let lifecycle = Self.statuses(of: runCodeUpdates)
        let inProgressIndex = try #require(lifecycle.firstIndex(of: .inProgress))
        let completedIndex = try #require(lifecycle.firstIndex(of: .completed))
        #expect(inProgressIndex < completedIndex)

        // The converged container: status, title, rawInput, rawOutput.
        #expect(accumulated.status == .value(.completed))
        #expect(accumulated.title == .value(Self.runCodeToolName))
        let rawInput = try #require(
            jsonObject(of: patchValue(accumulated.rawInput)),
            "expected the runCode rawInput object, got \(accumulated.rawInput)")
        let codeArgument = try #require(
            jsonString(of: rawInput["code"]),
            "expected the runCode rawInput object, got \(accumulated.rawInput)")
        #expect(codeArgument == Self.noteCode)

        // The written line rides the `runCode` call's answer.
        #expect(try Self.answerText(of: accumulated).contains(Self.noteContent))
    }

    // MARK: - Proof 4: prompt order

    /// The tool prompt keeps §8.1's order on the wire: the response that
    /// names the user message acknowledges first, then `user_message`, `running`, the tool
    /// updates, and one `idle(end_turn)` as the terminator.
    ///
    /// The acknowledgement is read on the BYTES, through the harness
    /// ``WireTap``. The collector starts at the client's notification
    /// handler, which stands downstream of the JSON-RPC response the
    /// same wire carried, so the collector alone cannot place the
    /// response against the echo.
    ///
    /// The marker assertion is an ORDERED SUBSEQUENCE, and it permits
    /// gaps. It proves that the four markers stand in that relative
    /// order and nothing more: it does not prove that exactly one
    /// `running` arrives, because a second `running` after a
    /// `tool_call_update` also satisfies it, and it says nothing about
    /// the update kinds the ordered claim leaves out.
    @Test(.timeLimit(.minutes(1)))
    func theToolPromptKeepsTheWireOrder() async throws {
        let (fixture, updates) = try await Self.runNotePrompt(
            label: "TierTwoTests-order", tapsWire: true)
        let wireTap = try #require(fixture.harness.wireTap)
        let wireLines = await wireTap.lines
        await fixture.close()

        // §8.1's MUST: the acknowledgement of `session/prompt` stands on
        // the wire before the `user_message` echo, and both name the same
        // user message.
        let acknowledgement = try #require(Self.acknowledgement(in: wireLines))
        let echo = try #require(Self.userMessage(in: wireLines))
        #expect(acknowledgement.index < echo.index)
        #expect(echo.messageId == acknowledgement.messageId)

        let markers = updates.compactMap(Self.orderMarker(of:))
        expectOrderedSubsequence(
            [Self.userMessageMarker, "running", "tool_call_update", "idle"], in: markers)
        #expect(markers.first == Self.userMessageMarker)
        #expect(ScriptedPromptFixture.idleCount(in: updates) == 1)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
        if case .stateUpdate(.idle) = try #require(updates.last).update {} else {
            Issue.record("expected idle as the terminator, got \(updates)")
        }
    }

    // MARK: - Proof 5: enable and disable

    /// Project config `shell: false` keeps the shell namespace off the
    /// session, confirmed from the client end: the snippet sees no
    /// `tools.shell` while `tools.files` stands, and no terminal
    /// update ever reaches the wire.
    @Test(.timeLimit(.minutes(1)))
    func aDisabledShellSectionKeepsTheShellNamespaceOffTheSession() async throws {
        let code = """
            return (typeof tools.shell) + "|" + (typeof tools.files);
            """

        let (fixture, updates) = try await Self.runToolPrompt(
            code: code,
            label: "TierTwoTests-disable",
            projectConfigYAML: "tools:\n  shell: false\n")
        let answerText = try Self.snippetAnswerText(in: updates)
        let surface = await fixture.harness.agent.sessions[fixture.sessionId]?.surface
        await fixture.close()

        #expect(answerText.contains("undefined|"))
        #expect(!answerText.contains("|undefined"))
        #expect(!updates.contains { $0.update.kind == .terminalOutputChunk })
        #expect(!updates.contains { $0.update.kind == .terminalUpdate })
        #expect(surface?.shellOutput == nil)
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - Proof 6: MCP through the shipped ScriptedServer

    /// A client-declared MCP server — the shipped `mcp-test-server`,
    /// which is `ScriptedServer` over stdio — mounts under its own
    /// name: the surface listing shows `alpha.echo` with no `mcp`
    /// segment, the call round-trips through the real subprocess, and
    /// the answer correlates to the tool call that ran it.
    ///
    /// The two claims read two SEPARATE sources. The snippet reduces
    /// the `help()` listing to its own two answers, so the mounted-path
    /// lines carry no verb text; the echoed line carries the ping and
    /// nothing else. Neither assertion can therefore pass on the other
    /// one's source.
    ///
    /// The correlation is plan.md §20.1's: the MCP call runs inside the
    /// snippet, so it opens no ACP tool call of its own, and its answer
    /// reaches the wire under the `runCode` call that carried the
    /// snippet's result.
    /// The proof reads every `tool_call_update` of the prompt and asserts
    /// that the ping stands in exactly one call's ANSWER — that call's —
    /// and in no other.
    @Test(.timeLimit(.minutes(1)))
    func aClientDeclaredMCPServerMountsUnderItsOwnNoun() async throws {
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        let server = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: AbsolutePath(rawValue: serverCommand),
                name: Self.mcpServerName,
                args: [ServerMode.flagName, ServerMode.echo.rawValue]))
        let echoPath = "\(Self.mcpServerName).\(ScriptedServer.echoToolName)"
        let prefixedPath = "mcp.\(ScriptedServer.echoToolName)"

        let (fixture, updates) = try await Self.runToolPrompt(
            code: try Self.mcpCode(echoPath: echoPath, prefixedPath: prefixedPath),
            label: "TierTwoTests-mcp",
            mcpServers: [server])
        let answeringId = Self.runCodeCallId
        let answerText = try Self.snippetAnswerText(in: updates)
        let accumulated = try await Self.accumulatedToolCall(of: fixture, id: answeringId)
        let answeringIds = try Self.toolCallIdsAnswering(text: Self.echoPing, in: updates)
        let pool = await fixture.harness.agent.sessions[fixture.sessionId]?.surface.serverPool
        await pool?.shutdownAll()
        await fixture.close()

        // The surface listing alone: the echo verb mounts under the
        // server's own noun, and under no `mcp` noun.
        #expect(
            answerText.contains(
                Self.outcomeLine(label: Self.mountedPathLabel, value: Self.snippetTrue)))
        #expect(
            answerText.contains(
                Self.outcomeLine(label: Self.prefixedPathLabel, value: Self.snippetFalse)))

        // The round trip alone: the real subprocess echoed the ping.
        #expect(
            answerText.contains(
                Self.outcomeLine(label: Self.echoedAnswerLabel, value: Self.echoPing)))

        // The correlation: the answer rides the call that carried the
        // snippet's result, and no other call of the prompt carries it.
        #expect(answeringIds == [answeringId])
        #expect(accumulated.status == .value(.completed))
        // The accumulated call is read through `answerText(of:)`, thus
        // the text holds the ANSWER alone. A reader of the whole update
        // would take the `rawInput` as well, and the snippet source in
        // that field carries the ping, so the REQUEST would answer this
        // assertion.
        let accumulatedText = try Self.answerText(of: accumulated)
        #expect(accumulatedText.contains(Self.echoPing))
        #expect(ScriptedPromptFixture.idleStopReason(in: updates) == .endTurn)
    }

}
