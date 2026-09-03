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
/// scripted model — the seven proofs, driven and asserted through
/// `FoundationModelsACPClient`.
///
/// The discipline is §20.1's: check the filesystem, never the
/// transcript. A "file written" claim is proven by reading the file
/// from disk.
///
/// Two card notes, recorded on task `^qg1rfct`:
///
/// - Proof 7 asserts the LANDED shell-output vocabulary. The card
///   predates the terminal stream; plan.md §11.8 says "When the
///   terminal stream lands, `shell` moves its bytes to
///   `terminal_output_chunk` and the tool call carries a `terminal`
///   reference", and that landing shipped. The streamed-chunks proof
///   therefore reads `terminal_output_chunk` and `terminal_update`,
///   and the convergence proof reads `ACPSessionState.terminals`.
/// - Proof 3 asserts `locations` from the structured per-call record
///   (plan.md §11.5, task `^9jfmhh0`): the note turn runs with
///   `recordsChanges: true`, so the write attaches its `FileChangeSet`
///   and the projection fills the paths from it, never from a
///   rendered string.
/// - Proof 1 reads the surface NAMES from a direct
///   `ToolCatalog.makeRegistry` call (task `^7dwcz2a`), because
///   `journalOp` and `group` are `APISurface.Entry` properties and the
///   sandbox's `help()` renders paths alone. Its three `CatalogContext`
///   facts — the root set, the decoded config section, and the resolved
///   profile — are driven and asserted through
///   `FoundationModelsACPClient`, like the other six proofs.
@Suite struct TierTwoTests {
    // MARK: - Constants

    /// The prompt of every scripted tool turn.
    private static let promptText = "Run the scripted tool turn"

    /// The name of the code-mode session tool the scripts invoke.
    private static let runCodeToolName = "runCode"

    /// The name of the collector session tool. `runCode` mounts in the
    /// background and answers a pending envelope, so every tool turn
    /// plays `wait` after it to settle the run inside the turn.
    private static let waitToolName = "wait"

    /// The SDK id of the first scripted tool call — the `runCode` call.
    private static let runCodeCallId = ScriptedSessionBackend.scriptedCallIdPrefix + "1"

    /// The SDK id of the second scripted tool call — the `wait` call.
    private static let waitCallId = ScriptedSessionBackend.scriptedCallIdPrefix + "2"

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

    /// The project config of the note turn: change recording on.
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

    /// The lines the streamed-shell proof prints, with a pause between
    /// each pair, so the output arrives as more than one chunk.
    private static let streamedLines = ["line-1", "line-2", "line-3"]

    /// The pause between two printed lines, as the shell `sleep`
    /// argument.
    private static let streamedPauseSeconds = "0.2"

    /// The fewest separate output chunks the streamed run must
    /// produce: the pauses split the three lines across at least two
    /// pipe reads.
    private static let minimumStreamedChunkCount = 2

    /// The `wait` plays of the streamed-shell turn: the first settles
    /// the `runCode` run, and the second joins the nested background
    /// shell run, so the run settles inside the turn.
    private static let streamWaitStepCount = 2

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

    /// The script of one tool turn: `runCode` with `code`, then
    /// `waitStepCount` plays of `wait`, then the turn end.
    ///
    /// One `wait` settles the `runCode` run itself. A snippet that
    /// starts a nested background run — `tools.shell.execute` — needs
    /// a second `wait`: the nested run registers only when the snippet
    /// resolves, after the first `wait` took its pending snapshot.
    ///
    /// - Parameters:
    ///   - code: The snippet the turn runs.
    ///   - waitStepCount: How many `wait` plays follow the snippet.
    /// - Returns: The script.
    /// - Throws: The arguments-encoding error.
    private static func makeToolTurnScript(
        code: String, waitStepCount: Int = 1
    ) throws -> [ScriptedTurnStep] {
        let waits = [ScriptedTurnStep](
            repeating: .toolCall(name: waitToolName, argumentsJSON: "{}"),
            count: waitStepCount)
        return [
            .toolCall(name: runCodeToolName, argumentsJSON: try runCodeArgumentsJSON(code: code))
        ] + waits + [.endTurn]
    }

    /// The write-then-read-back snippet of the projection proofs. Each
    /// step returns its in-band correction when one arrives, so a
    /// failure names itself in the wait output.
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

    /// One labeled outcome line of ``compositionCode(insidePath:outsidePath:)``.
    ///
    /// - Parameters:
    ///   - label: The step's outcome label.
    ///   - value: The value the step is expected to report.
    /// - Returns: The line the snippet emits for that step.
    private static func outcomeLine(label: String, value: String) -> String {
        "\(label)=\(value)"
    }

    // MARK: - Turn driver

    /// Wires the fixture, prompts one scripted tool turn, waits for
    /// the idle terminator, and flushes the coalescing buffer.
    ///
    /// - Parameters:
    ///   - code: The snippet the turn runs.
    ///   - label: The directory label of the calling proof.
    ///   - waitStepCount: How many `wait` plays follow the snippet.
    ///   - workingDirectory: The pre-made session working directory,
    ///     or `nil` to let the fixture make one.
    ///   - projectConfigYAML: The project `config.yaml`, or `nil`.
    ///   - mcpServers: The client's per-session MCP servers, or `nil`.
    ///   - additionalDirectories: The `session/new` additional roots,
    ///     or `nil` for none.
    ///   - flashContainer: The resident model the flash slot loads, or
    ///     `nil` to let every slot play the turn script. The
    ///     composition proof passes a recording librarian here, because
    ///     `ToolCatalog.sessionSurface` hands `profile.flash` to
    ///     `searchTools`.
    /// - Returns: The fixture and the collected sequence at idle.
    /// - Throws: Whatever the wiring or the prompt throws.
    private static func runToolTurn(
        code: String,
        label: String,
        waitStepCount: Int = 1,
        workingDirectory: URL? = nil,
        projectConfigYAML: String? = nil,
        mcpServers: [FoundationModelsACP.MCPServer]? = nil,
        additionalDirectories: [AbsolutePath]? = nil,
        flashContainer: (any LoadedLLMContainer)? = nil
    ) async throws -> (fixture: ScriptedTurnFixture, updates: [UpdateSessionNotification]) {
        let script = try makeToolTurnScript(code: code, waitStepCount: waitStepCount)
        var loader = makeScriptedModelLoader(script: script)
        if let flashContainer {
            let scriptedContainer = loader.makeLLMContainer
            loader.makeLLMContainer = { slot in
                slot == .flash ? flashContainer : scriptedContainer(slot)
            }
        }
        let fixture = try await ScriptedTurnFixture.make(
            loader: loader,
            label: label,
            workingDirectory: workingDirectory,
            projectConfigYAML: projectConfigYAML,
            mcpServers: mcpServers,
            additionalDirectories: additionalDirectories)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.harness.flushPendingChunks()
        return (fixture, updates)
    }

    /// Runs the shared write-then-read-back note turn, with change
    /// recording on.
    ///
    /// - Parameter label: The directory label of the calling proof.
    /// - Returns: The fixture and the collected sequence at idle.
    /// - Throws: Whatever the wiring or the prompt throws.
    private static func runNoteTurn(
        label: String
    ) async throws -> (fixture: ScriptedTurnFixture, updates: [UpdateSessionNotification]) {
        try await runToolTurn(
            code: noteCode, label: label, projectConfigYAML: recordsChangesConfigYAML)
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
        of fixture: ScriptedTurnFixture, id: String
    ) throws -> ToolCallUpdate {
        let state = try #require(fixture.harness.client.sessions[fixture.sessionId])
        return try #require(state.toolCalls[ToolCallId(rawValue: id)])
    }

    /// The order marker of one notification, for the §8.1 order proof:
    /// the echo, the running and idle states, and the tool updates.
    /// Every other update kind is not part of the ordered claim.
    ///
    /// - Parameter notification: The notification to classify.
    /// - Returns: The marker, or `nil` when the update is not ordered.
    private static func orderMarker(of notification: UpdateSessionNotification) -> String? {
        switch notification.update {
        case .userMessage: "user_message"
        case .stateUpdate(.running): "running"
        case .stateUpdate(.idle): "idle"
        case .toolCallUpdate: "tool_call_update"
        default: nil
        }
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
    /// scripted tool turn:
    ///
    /// - **The root set.** The session opens with an additional root. A
    ///   read under that root answers the planted content, and a read
    ///   outside the union of the cwd and that root refuses in band, so
    ///   the built verbs confine to `cwd` plus `additionalDirectories`.
    /// - **The decoded config section.** The project config sets
    ///   `tools.files.readOnly`. The write refuses in band with the
    ///   capability's read-only correction, and nothing lands on disk.
    /// - **The resolved profile.** The flash slot loads a recording stub
    ///   librarian that answers one selection. The turn's `searchTools`
    ///   call records the selection prompt on that slot, and the answer
    ///   reports the verb the librarian selected.
    @Test(.timeLimit(.minutes(1)))
    func theCatalogComposesTheSurfaceFromTheLoadedConfiguration() async throws {
        let cwd = makeResolvedDirectory(label: "TierTwoTests-composition-repo")
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        try ScriptedTurnFixture.writeProjectConfig(
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

    /// Drives the wire half of proof 1: one scripted tool turn on a
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

        let (fixture, updates) = try await runToolTurn(
            code: try compositionCode(
                insidePath: insideFile.path, outsidePath: outsideFile.path),
            label: "TierTwoTests-composition-session",
            projectConfigYAML: readOnlyFilesConfigYAML,
            additionalDirectories: [try #require(AbsolutePath(rawValue: additionalRoot.path))],
            flashContainer: ScriptedLLMContainer(
                script: [.textDelta(librarianSelectionJSON), .endTurn],
                recorder: librarianRecorder))
        let waitText = try encodedText(of: toolCallUpdates(in: updates, for: waitCallId))
        let librarianPrompts = await librarianRecorder.prompts
        let refusedWrite = fixture.cwd.appendingPathComponent(refusedWriteFileName)
        await fixture.close()

        // The root set is the cwd plus `additionalDirectories`: the read
        // under the additional root answers content, and the read
        // outside the union answers the confinement correction.
        #expect(
            waitText.contains(
                outcomeLine(label: insideReadLabel, value: additionalRootContent)))
        #expect(
            waitText.contains(
                outcomeLine(label: outsideReadLabel, value: confinementRefusalOpening)))

        // The decoded `files` section reached the built verbs: the write
        // answers the read-only correction, and the disk is the truth
        // that nothing was written (plan.md §20.1).
        #expect(
            waitText.contains(
                outcomeLine(label: refusedWriteLabel, value: readOnlyRefusalMarker)))
        #expect(!FileManager.default.fileExists(atPath: refusedWrite.path))

        // The resolved profile reached the librarian slot: the flash
        // slot's model answered the selection call for this task, and
        // `searchTools` reports the verb that answer named.
        #expect(librarianPrompts.contains { $0.contains(librarianTask) })
        #expect(waitText.contains(executeVerbPath))
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - Proof 2: confinement through the protocol

    /// A `tools.files.read` of a path outside the root set refuses IN
    /// BAND: the `correction` rides the wait call's `tool_call_update`,
    /// nothing throws — the turn still ends `end_turn` and the call
    /// completes — and the outside file's content never crosses the
    /// wire. The sandbox is the only gate: no permission request is
    /// ever pending (plan.md §11.7).
    @Test(.timeLimit(.minutes(1)))
    func anOutOfRootReadRefusesInBandThroughTheCorrectionField() async throws {
        let outside = makeResolvedDirectory(label: "TierTwoTests-outside")
        let secretFile = outside.appendingPathComponent("secret.txt")
        try Self.outsideSecret.write(to: secretFile, atomically: true, encoding: .utf8)
        let code = """
            const read = await tools.files.read({ path: \(try Self.jsonStringLiteral(text: secretFile.path)), format: "plain" });
            return read;
            """

        let (fixture, updates) = try await Self.runToolTurn(
            code: code, label: "TierTwoTests-confinement")
        let waitUpdates = Self.toolCallUpdates(in: updates, for: Self.waitCallId)
        let waitText = try Self.encodedText(of: waitUpdates)
        let wireText = try Self.encodedWireText(updates: updates)
        let accumulated = try await Self.accumulatedToolCall(of: fixture, id: Self.waitCallId)
        let pendingPermissionCount = await MainActor.run {
            fixture.harness.client.sessions[fixture.sessionId]?.pendingPermissionRequests.count
        }
        await fixture.close()

        #expect(waitText.contains(Self.confinementRefusalMarker))
        #expect(waitText.contains("correction"))
        #expect(!wireText.contains(Self.outsideSecret))
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
        if case .value(let status) = accumulated.status {
            #expect(status == .completed)
        } else {
            Issue.record("the wait call never carried a status")
        }
        #expect(pendingPermissionCount == 0)
    }

    // MARK: - Proof 3: projection fidelity

    /// A real tool call becomes a correct `tool_call_update` upsert:
    /// one stable `toolCallId` from creation to completion, the title
    /// on the first report, `in_progress` before `completed`,
    /// `rawInput` carrying the call's real arguments, and `rawOutput`
    /// carrying the tool's real answer — read from
    /// `ACPSessionState.toolCalls`. The file the snippet claims to
    /// have written is read back from disk, never from the transcript.
    @Test(.timeLimit(.minutes(1)))
    func aRealToolCallProjectsAStableUpsertLifecycle() async throws {
        let (fixture, updates) = try await Self.runNoteTurn(label: "TierTwoTests-projection")
        let runCodeUpdates = Self.toolCallUpdates(in: updates, for: Self.runCodeCallId)
        let accumulated = try await Self.accumulatedToolCall(of: fixture, id: Self.runCodeCallId)
        let waitAccumulated = try await Self.accumulatedToolCall(of: fixture, id: Self.waitCallId)
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
        guard case .value(.object(let rawInput)) = accumulated.rawInput,
            case .string(let codeArgument) = rawInput["code"] ?? .null
        else {
            Issue.record("expected the runCode rawInput object, got \(accumulated.rawInput)")
            return
        }
        #expect(codeArgument == Self.noteCode)
        guard case .value(let waitOutput) = waitAccumulated.rawOutput else {
            Issue.record("expected the wait rawOutput value, got \(waitAccumulated.rawOutput)")
            return
        }
        #expect(try Self.encodedText(of: waitOutput).contains(Self.noteContent))
    }

    // MARK: - Proof 4: turn order

    /// The tool turn keeps §8.1's order on the wire: the `{}` response
    /// acknowledges first (the prompt call returns), then
    /// `user_message`, `running`, the tool updates, and one
    /// `idle(end_turn)` as the terminator.
    @Test(.timeLimit(.minutes(1)))
    func theToolTurnKeepsTheWireOrder() async throws {
        let (fixture, updates) = try await Self.runNoteTurn(label: "TierTwoTests-order")
        await fixture.close()

        let markers = updates.compactMap(Self.orderMarker(of:))
        expectOrderedSubsequence(
            ["user_message", "running", "tool_call_update", "idle"], in: markers)
        #expect(markers.first == "user_message")
        #expect(ScriptedTurnFixture.idleCount(in: updates) == 1)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
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

        let (fixture, updates) = try await Self.runToolTurn(
            code: code,
            label: "TierTwoTests-disable",
            projectConfigYAML: "tools:\n  shell: false\n")
        let waitText = try Self.encodedText(
            of: Self.toolCallUpdates(in: updates, for: Self.waitCallId))
        let surface = await fixture.harness.agent.sessions[fixture.sessionId]?.surface
        await fixture.close()

        #expect(waitText.contains("undefined|"))
        #expect(!waitText.contains("|undefined"))
        #expect(!updates.contains { $0.update.kind == .terminalOutputChunk })
        #expect(!updates.contains { $0.update.kind == .terminalUpdate })
        #expect(surface?.shellOutput == nil)
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - Proof 6: MCP through the shipped ScriptedServer

    /// A client-declared MCP server — the shipped `mcp-test-server`,
    /// which is `ScriptedServer` over stdio — mounts under its own
    /// name: the surface listing shows `alpha.echo` with no `mcp`
    /// segment, the call round-trips through the real subprocess, and
    /// the answer lands under the wait call's stable `toolCallId`.
    @Test(.timeLimit(.minutes(1)))
    func aClientDeclaredMCPServerMountsUnderItsOwnNoun() async throws {
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        let server = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: try #require(AbsolutePath(rawValue: serverCommand)),
                name: Self.mcpServerName,
                args: [ServerMode.flagName, ServerMode.echo.rawValue]))
        let code = """
            const listing = help();
            const answer = await tools.\(Self.mcpServerName).\(ScriptedServer.echoToolName)({ \(ScriptedServer.echoTextArgument): "\(Self.echoPing)" });
            return { listing: listing, answer: answer };
            """

        let (fixture, updates) = try await Self.runToolTurn(
            code: code, label: "TierTwoTests-mcp", mcpServers: [server])
        let waitText = try Self.encodedText(
            of: Self.toolCallUpdates(in: updates, for: Self.waitCallId))
        let accumulated = try await Self.accumulatedToolCall(of: fixture, id: Self.waitCallId)
        let pool = await fixture.harness.agent.sessions[fixture.sessionId]?.surface.serverPool
        await pool?.shutdownAll()
        await fixture.close()

        let echoPath = "\(Self.mcpServerName).\(ScriptedServer.echoToolName)"
        #expect(waitText.contains(echoPath))
        #expect(!waitText.contains("mcp.\(ScriptedServer.echoToolName)"))
        #expect(waitText.contains(Self.echoPing))
        #expect(accumulated.status == .value(.completed))
        let accumulatedText = try Self.encodedText(of: accumulated)
        #expect(accumulatedText.contains(Self.echoPing))
        #expect(ScriptedTurnFixture.idleStopReason(in: updates) == .endTurn)
    }

    // MARK: - Proof 7: streamed shell output

    /// A real `tools.shell.execute` that prints several lines with
    /// pauses streams its bytes live on the terminal stream (plan.md
    /// §11.8, the landed vocabulary — see the suite comment): the
    /// run's `tool_call_update` announces the `Terminal` reference
    /// first, the `terminal_output_chunk` updates follow in order and
    /// concatenate to the complete output, the exit `terminal_update`
    /// carries the authoritative replacement, and the container
    /// converges — `ACPSessionState.terminals` holds the complete
    /// bytes, and the settled call in `ACPSessionState.toolCalls`
    /// completes with the `Terminal` reference.
    @Test(.timeLimit(.minutes(1)))
    func aStreamedShellRunRidesTheTerminalStreamAndConverges() async throws {
        // The snippet omits `workingDirectory` on purpose: the shell
        // composition defaults the run to the session cwd (task
        // ^fzx2r16), and the trailing `pwd -P` line proves the run
        // landed there.
        let command = Self.streamedLines
            .map { "echo \($0)" }
            .joined(separator: "; sleep \(Self.streamedPauseSeconds); ")
            + "; pwd -P"
        let cwd = makeResolvedDirectory(label: "TierTwoTests-stream-repo")
        let code = """
            return await tools.shell.execute({ command: \(try Self.jsonStringLiteral(text: command)) });
            """
        let expectedOutput = Self.streamedLines.map { $0 + "\n" }.joined() + cwd.path + "\n"

        let (fixture, _) = try await Self.runToolTurn(
            code: code,
            label: "TierTwoTests-stream",
            waitStepCount: Self.streamWaitStepCount,
            workingDirectory: cwd)
        // The exit report rides the terminal projection task, so it can
        // land after the turn's idle: wait for it, never sleep for it.
        let updates = try await ScriptedTurnFixture.waitForUpdates(
            of: fixture.collector, toReach: "the terminal exit report"
        ) { collected in
            collected.contains { notification in
                guard case .terminalUpdate(let update) = notification.update,
                    case .value = update.exitStatus
                else { return false }
                return true
            }
        }
        await fixture.harness.flushPendingChunks()

        // The run's identity: every chunk carries one terminalId, which
        // is the run's toolCallId (plan.md §11.8).
        let chunks = updates.compactMap { notification -> TerminalOutputChunk? in
            guard case .terminalOutputChunk(let chunk) = notification.update else { return nil }
            return chunk
        }
        #expect(chunks.count >= Self.minimumStreamedChunkCount)
        let terminalId = try #require(chunks.first?.terminalId)
        #expect(chunks.allSatisfy { $0.terminalId == terminalId })

        // The chunks concatenate, in arrival order, to the complete
        // output.
        var streamed = Data()
        for chunk in chunks {
            streamed.append(try #require(Data(base64Encoded: chunk.data)))
        }
        #expect(String(decoding: streamed, as: UTF8.self) == expectedOutput)

        // Order: the announcing tool_call_update precedes the first
        // chunk, and every chunk precedes the exit terminal_update.
        let announceIndex = try #require(
            updates.firstIndex { notification in
                guard case .toolCallUpdate(let update) = notification.update else { return false }
                return update.toolCallId.rawValue == terminalId.rawValue
            })
        let firstChunkIndex = try #require(
            updates.firstIndex { notification in
                guard case .terminalOutputChunk = notification.update else { return false }
                return true
            })
        let exitIndex = try #require(
            updates.firstIndex { notification in
                guard case .terminalUpdate(let update) = notification.update,
                    case .value = update.exitStatus
                else { return false }
                return true
            })
        let lastChunkIndex = try #require(
            updates.lastIndex { notification in
                guard case .terminalOutputChunk = notification.update else { return false }
                return true
            })
        #expect(announceIndex < firstChunkIndex)
        #expect(lastChunkIndex < exitIndex)

        // The exit report carries the authoritative replacement.
        guard case .terminalUpdate(let exitUpdate) = updates[exitIndex].update,
            case .value(let replacement) = exitUpdate.output
        else {
            Issue.record("expected the exit terminal_update to carry the output replacement")
            await fixture.close()
            return
        }
        let replaced = try #require(Data(base64Encoded: replacement.data))
        #expect(String(decoding: replaced, as: UTF8.self) == expectedOutput)

        // Convergence in the container: the terminal holds the complete
        // bytes, and the settled call completes with the Terminal
        // reference. The settlement rides `runSettled` and can land
        // after the exit report, so wait for the container to hold
        // the completed status first, never sleep for it.
        try await ScriptedTurnFixture.waitForCompletedToolCall(
            of: fixture.harness.client,
            sessionId: fixture.sessionId,
            id: ToolCallId(rawValue: terminalId.rawValue))
        let convergence = await MainActor.run {
            () -> (terminalText: String?, exited: Bool, call: ToolCallUpdate?) in
            guard let state = fixture.harness.client.sessions[fixture.sessionId] else {
                return (nil, false, nil)
            }
            let terminal = state.terminals[terminalId]
            let exited: Bool
            if case .value = terminal?.exitStatus { exited = true } else { exited = false }
            return (
                terminal.map { String(decoding: $0.output, as: UTF8.self) },
                exited,
                state.toolCalls[ToolCallId(rawValue: terminalId.rawValue)]
            )
        }
        await fixture.close()

        #expect(convergence.terminalText == expectedOutput)
        #expect(convergence.exited)
        // The accumulated call settles to the `completed` status —
        // Router forwards the nested run's terminal from the mailbox
        // to the outbox, and `runSettled` becomes the terminal
        // `tool_call_update` (§8.4, §11.6) — and carries the Terminal
        // reference, whose exit status marks the run ended.
        let settledCall = try #require(convergence.call)
        #expect(settledCall.status == .value(.completed))
        guard case .value(let content) = settledCall.content else {
            Issue.record("expected the settled call to carry content")
            return
        }
        #expect(
            content.contains { item in
                guard case .terminal(let terminal) = item else { return false }
                return terminal.terminalId == terminalId
            })
    }
}
