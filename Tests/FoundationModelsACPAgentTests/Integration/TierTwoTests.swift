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
/// `FoundationModelsACPClient`, and proof 8 beside them.
///
/// The discipline is §20.1's: check the filesystem, never the
/// transcript. A "file written" claim is proven by reading the file
/// from disk.
///
/// **Where the denial coverage lives.** Two doors refuse a path outside
/// the session root set, and this file drives both from the client end:
/// proof 2 refuses a READ through Multitool's `PathGuard`, and proof 8
/// refuses a shell WRITE through the seatbelt sandbox (plan.md §11.7).
/// Two suites in this target prove the same rule below the wire, and a
/// reader wanting the whole picture reads them beside the two proofs:
/// `SandboxCompositionTests` — `aWriteOutsideTheRootSetNeverLands` and
/// the empty-root-set, preflight and `/private` symlink regressions —
/// and `MultiRootConfinementTests.aPathOutsideTheRootUnionIsStillRefused`.
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

    /// The SDK id of the third scripted tool call — the second `wait`
    /// play, which a turn whose snippet started a nested background shell
    /// run needs, and under which that run's report reaches the wire.
    private static let nestedRunWaitCallId = ScriptedSessionBackend.scriptedCallIdPrefix + "3"

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

    /// The flag of the pending envelope a background `runCode` answers.
    /// It names the envelope apart from the run's own result, which
    /// reaches the wire through the following `wait` call.
    private static let pendingEnvelopeMarker = "\"pending\":true"

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

    /// The `wait` plays of a turn whose snippet starts a nested
    /// background shell run: the first settles the `runCode` run, and the
    /// second joins the shell run, so the run settles inside the turn.
    private static let shellWaitStepCount = 2

    /// What a proof waits for when it needs the shell run's exit report.
    private static let terminalExitLabel = "the terminal exit report"

    /// The file the sandbox proof asks a real sandboxed shell run to
    /// write OUTSIDE the session root set. It must never reach the disk.
    private static let escapedWriteFileName = "sandbox-escaped-write.txt"

    /// The content the escaping write would have carried.
    private static let escapedWriteContent = "tier two must never write outside the root set"

    /// The text a denied write reaches the terminal stream as. The
    /// seatbelt sandbox sends no message of its own: the kernel refuses
    /// the `open` with `EPERM`, and this is `strerror(3)` of that code,
    /// as `/bin/sh` prints it when a redirect fails.
    private static let sandboxDenialMarker = "Operation not permitted"

    /// The `status` a shell run report carries when the command ran to
    /// its own end. A sandboxed write that the kernel refuses still
    /// reports it: the command spawned and the redirect then failed.
    private static let completedRunStatus = "completed"

    /// The `exitCode` a shell command reports when it succeeded. The
    /// escaping write must not report it.
    private static let successExitCode = 0

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
    ///   - tapsWire: Whether the harness records the raw wire lines.
    ///     Only the turn-order proof reads them.
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
        flashContainer: (any LoadedLLMContainer)? = nil,
        tapsWire: Bool = false
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
            additionalDirectories: additionalDirectories,
            tapsWire: tapsWire)
        _ = try await fixture.harness.connection.prompt(
            AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: promptText))
        let updates = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.harness.flushPendingChunks()
        return (fixture, updates)
    }

    /// Runs the shared write-then-read-back note turn, with change
    /// recording on.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling proof.
    ///   - tapsWire: Whether the harness records the raw wire lines.
    /// - Returns: The fixture and the collected sequence at idle.
    /// - Throws: Whatever the wiring or the prompt throws.
    private static func runNoteTurn(
        label: String, tapsWire: Bool = false
    ) async throws -> (fixture: ScriptedTurnFixture, updates: [UpdateSessionNotification]) {
        try await runToolTurn(
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

    /// The exit status one notification carries, when it is a shell run's
    /// exit report.
    ///
    /// - Parameter notification: The notification to read.
    /// - Returns: The exit status, or `nil` when the notification is not
    ///   an exit report.
    private static func terminalExitStatus(
        of notification: UpdateSessionNotification
    ) -> TerminalExitStatus? {
        guard case .terminalUpdate(let update) = notification.update,
            case .value(let status) = update.exitStatus
        else { return nil }
        return status
    }

    /// Polls the collector until a shell run's exit report arrives.
    ///
    /// The exit report rides the terminal projection task, so it can land
    /// after the turn's idle: a proof waits for it, never sleeps for it.
    ///
    /// - Parameter collector: The collector to poll.
    /// - Returns: The collected sequence, the exit report in it.
    /// - Throws: `CancellationError` when the test is cancelled.
    private static func waitForTerminalExit(
        of collector: UpdateCollector
    ) async throws -> [UpdateSessionNotification] {
        try await ScriptedTurnFixture.waitForUpdates(
            of: collector, toReach: terminalExitLabel
        ) { collected in
            collected.contains { terminalExitStatus(of: $0) != nil }
        }
    }

    /// Every `terminal_output_chunk` in the sequence, in arrival order.
    ///
    /// - Parameter updates: The collected sequence.
    /// - Returns: The carried chunks.
    private static func terminalChunks(
        in updates: [UpdateSessionNotification]
    ) -> [TerminalOutputChunk] {
        updates.compactMap { notification in
            guard case .terminalOutputChunk(let chunk) = notification.update else { return nil }
            return chunk
        }
    }

    /// The streamed bytes of a shell run, decoded as text: every
    /// `terminal_output_chunk` of the sequence, concatenated in arrival
    /// order.
    ///
    /// - Parameter updates: The collected sequence.
    /// - Returns: The streamed text.
    /// - Throws: When one chunk does not decode as base64.
    private static func streamedTerminalText(
        in updates: [UpdateSessionNotification]
    ) throws -> String {
        let decoded = try terminalChunks(in: updates).map { chunk in
            try #require(Data(base64Encoded: chunk.data))
        }
        return String(decoding: Data(decoded.joined()), as: UTF8.self)
    }

    /// The `rawOutput` string one tool call carries.
    ///
    /// - Parameter update: The tool call to read.
    /// - Returns: The carried string, or `nil` when the field carries
    ///   none or carries something else.
    private static func rawOutputString(of update: ToolCallUpdate) -> String? {
        guard case .value(.string(let text)) = update.rawOutput else { return nil }
        return text
    }

    /// The shell run report a collecting `wait` call answered.
    ///
    /// The `wait` answer is the array of the runs it collected, and each
    /// entry's `detail` field holds the collected verb's own answer —
    /// for `tools.shell.execute`, the run report object. Both are
    /// decoded as JSON, so the proof reads the report's fields and never
    /// matches a rendered string.
    ///
    /// - Parameter update: The accumulated `wait` tool call.
    /// - Returns: The decoded run report.
    /// - Throws: When the call carries no decodable run report.
    private static func shellRunReport(of update: ToolCallUpdate) throws -> [String: Any] {
        let collected = try #require(rawOutputString(of: update))
        let runs = try JSONSerialization.jsonObject(with: Data(collected.utf8))
        let detail = try #require((runs as? [[String: Any]])?.first?["detail"] as? String)
        let report = try JSONSerialization.jsonObject(with: Data(detail.utf8))
        return try #require(report as? [String: Any])
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

    /// The index of the `{}` acknowledgement of `session/prompt` in the
    /// recorded wire lines.
    ///
    /// `PromptResponse` declares one optional `_meta`, so the
    /// acknowledgement encodes as an empty result object. `initialize`
    /// and `session/new` each answer a filled result, so an empty
    /// result names the prompt acknowledgement alone.
    ///
    /// - Parameter lines: The recorded wire lines, in wire order.
    /// - Returns: The index, or `nil` when no such line arrived.
    private static func acknowledgementIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            guard let result = decodedObject(of: line)?["result"] as? [String: Any] else {
                return false
            }
            return result.isEmpty
        }
    }

    /// The index of the first `user_message` notification in the
    /// recorded wire lines.
    ///
    /// - Parameter lines: The recorded wire lines, in wire order.
    /// - Returns: The index, or `nil` when no echo arrived.
    private static func userMessageIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            guard let params = decodedObject(of: line)?["params"] as? [String: Any],
                let update = params["update"] as? [String: Any]
            else { return false }
            return update["sessionUpdate"] as? String == userMessageMarker
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
    /// wire.
    ///
    /// The mechanism the proof exercises is the files capability's own
    /// path check — Multitool's `PathGuard`, whose wording the matched
    /// marker carries. The seatbelt sandbox is NOT the gate here:
    /// plan.md §11.7 says the sandbox "bounds writing and deleting
    /// only. Reads are free", and this proof reads.
    ///
    /// The pending-permission assertion is a REGRESSION TRIPWIRE, and
    /// not evidence of the refusal. No code path in this package sends
    /// `session/request_permission` (plan.md §11.7), and
    /// ``RecordingClient`` therefore carries no configurable permission
    /// answer, so the count cannot rise today. The assertion fails on
    /// the day a permission request is added.
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
        // The tripwire, not the evidence: it fails on the day a
        // permission request is added (plan.md §11.7).
        #expect(pendingPermissionCount == 0)
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
    /// The two calls of the turn answer different things, and the proof
    /// reads both. `runCode` mounts the run in the background, so ITS
    /// `rawOutput` is the pending envelope that names the completion
    /// token. The snippet's own result reaches the wire through the
    /// `wait` call, so the WAIT call's `rawOutput` is the one that
    /// carries the written line.
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

        // The `runCode` call answers the pending envelope, because the
        // run mounts in the background. The written line is not there.
        guard case .value(.string(let runCodeOutput)) = accumulated.rawOutput else {
            Issue.record("expected the runCode rawOutput string, got \(accumulated.rawOutput)")
            return
        }
        #expect(runCodeOutput.contains(Self.pendingEnvelopeMarker))
        #expect(!runCodeOutput.contains(Self.noteContent))

        // The `wait` call answers the snippet's own result, so it is the
        // call whose `rawOutput` carries the written line.
        guard case .value(let waitOutput) = waitAccumulated.rawOutput else {
            Issue.record("expected the wait rawOutput value, got \(waitAccumulated.rawOutput)")
            return
        }
        #expect(try Self.encodedText(of: waitOutput).contains(Self.noteContent))
    }

    // MARK: - Proof 4: turn order

    /// The tool turn keeps §8.1's order on the wire: the `{}` response
    /// acknowledges first, then `user_message`, `running`, the tool
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
    func theToolTurnKeepsTheWireOrder() async throws {
        let (fixture, updates) = try await Self.runNoteTurn(
            label: "TierTwoTests-order", tapsWire: true)
        let wireTap = try #require(fixture.harness.wireTap)
        let wireLines = await wireTap.lines
        await fixture.close()

        // §8.1's MUST: the `{}` acknowledgement of `session/prompt`
        // stands on the wire before the `user_message` echo.
        let acknowledgementIndex = try #require(Self.acknowledgementIndex(in: wireLines))
        let echoIndex = try #require(Self.userMessageIndex(in: wireLines))
        #expect(acknowledgementIndex < echoIndex)

        let markers = updates.compactMap(Self.orderMarker(of:))
        expectOrderedSubsequence(
            [Self.userMessageMarker, "running", "tool_call_update", "idle"], in: markers)
        #expect(markers.first == Self.userMessageMarker)
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
    /// reaches the wire under the `wait` call that collected the run.
    /// The proof reads every `tool_call_update` of the turn and asserts
    /// that the ping stands in exactly one call's ANSWER — the wait
    /// call's — and in no other.
    @Test(.timeLimit(.minutes(1)))
    func aClientDeclaredMCPServerMountsUnderItsOwnNoun() async throws {
        let serverCommand = try BuiltProductLocator.mcpTestServerURL().path
        let server = FoundationModelsACP.MCPServer.stdio(
            MCPServerStdio(
                command: try #require(AbsolutePath(rawValue: serverCommand)),
                name: Self.mcpServerName,
                args: [ServerMode.flagName, ServerMode.echo.rawValue]))
        let echoPath = "\(Self.mcpServerName).\(ScriptedServer.echoToolName)"
        let prefixedPath = "mcp.\(ScriptedServer.echoToolName)"

        let (fixture, updates) = try await Self.runToolTurn(
            code: try Self.mcpCode(echoPath: echoPath, prefixedPath: prefixedPath),
            label: "TierTwoTests-mcp",
            mcpServers: [server])
        let waitText = try Self.encodedText(
            of: Self.toolCallUpdates(in: updates, for: Self.waitCallId))
        let accumulated = try await Self.accumulatedToolCall(of: fixture, id: Self.waitCallId)
        let answeringIds = try Self.toolCallIdsAnswering(text: Self.echoPing, in: updates)
        let pool = await fixture.harness.agent.sessions[fixture.sessionId]?.surface.serverPool
        await pool?.shutdownAll()
        await fixture.close()

        // The surface listing alone: the echo verb mounts under the
        // server's own noun, and under no `mcp` noun.
        #expect(
            waitText.contains(
                Self.outcomeLine(label: Self.mountedPathLabel, value: Self.snippetTrue)))
        #expect(
            waitText.contains(
                Self.outcomeLine(label: Self.prefixedPathLabel, value: Self.snippetFalse)))

        // The round trip alone: the real subprocess echoed the ping.
        #expect(
            waitText.contains(
                Self.outcomeLine(label: Self.echoedAnswerLabel, value: Self.echoPing)))

        // The correlation: the answer rides the call that ran it, and
        // no other call of the turn carries it.
        #expect(answeringIds == [Self.waitCallId])
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
            waitStepCount: Self.shellWaitStepCount,
            workingDirectory: cwd)
        let updates = try await Self.waitForTerminalExit(of: fixture.collector)
        await fixture.harness.flushPendingChunks()

        // The run's identity: every chunk carries one terminalId, which
        // is the run's toolCallId (plan.md §11.8).
        let chunks = Self.terminalChunks(in: updates)
        #expect(chunks.count >= Self.minimumStreamedChunkCount)
        let terminalId = try #require(chunks.first?.terminalId)
        #expect(chunks.allSatisfy { $0.terminalId == terminalId })

        // The chunks concatenate, in arrival order, to the complete
        // output.
        #expect(try Self.streamedTerminalText(in: updates) == expectedOutput)

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
            updates.firstIndex { Self.terminalExitStatus(of: $0) != nil })
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

    // MARK: - Proof 8: the sandbox denies a shell write outside the root

    /// A real sandboxed `tools.shell.execute` that redirects into a path
    /// OUTSIDE the session root set never lands the file: the target path
    /// holds nothing afterwards, read from disk.
    ///
    /// **The mechanism, named by measurement.** The gate is the seatbelt
    /// sandbox `SandboxComposition` builds over the session root set,
    /// which plan.md §11.7 states is the ONLY gate on the shell
    /// capability. It is NOT Multitool's `PathGuard`: `PathGuard` bounds
    /// the files verbs, and §11.7 bounds it to writing and deleting, so
    /// proof 2 — which refuses a READ through `PathGuard` — and this
    /// proof measure two different doors.
    ///
    /// **No named sandbox message reaches the wire, and this proof claims
    /// none.** The sandbox is a kernel boundary, so the command RUNS: the
    /// kernel refuses the `open` of the redirect with `EPERM`, and the
    /// only refusal text anywhere on the wire is `/bin/sh`'s own —
    /// ``sandboxDenialMarker``, measured on the terminal stream. The
    /// claim is that the write did not land, and the disk is the proof of
    /// it. The streamed message and the run report's non-zero `exitCode`
    /// are the evidence that the kernel is what stopped it.
    ///
    /// The exit code is read from the run report the collecting `wait`
    /// call answered, not from the ACP exit report: `TerminalStream`
    /// sends an EMPTY `TerminalExitStatus`, whose presence marks the
    /// terminal exited and which carries neither a code nor a signal.
    ///
    /// The composition-level coverage of the same rule stands beside this
    /// proof, and a reader wanting the whole picture reads all three:
    /// `SandboxCompositionTests.aWriteOutsideTheRootSetNeverLands` drives
    /// this denial through a directly built registry, and
    /// `MultiRootConfinementTests.aPathOutsideTheRootUnionIsStillRefused`
    /// proves the files verbs refuse a path outside the root union. This
    /// proof is the client-end projection of the same denial.
    @Test(.timeLimit(.minutes(1)))
    func aSandboxedShellWriteOutsideTheRootSetNeverLands() async throws {
        let cwd = makeResolvedDirectory(label: "TierTwoTests-sandbox-repo")
        let outside = makeResolvedDirectory(label: "TierTwoTests-sandbox-outside")
        let escaped = outside.appendingPathComponent(Self.escapedWriteFileName)
        let command = "printf '\(Self.escapedWriteContent)' > '\(escaped.path)'"
        let code = """
            return await tools.shell.execute({ command: \(try Self.jsonStringLiteral(text: command)) });
            """

        let (fixture, turnUpdates) = try await Self.runToolTurn(
            code: code,
            label: "TierTwoTests-sandbox",
            waitStepCount: Self.shellWaitStepCount,
            workingDirectory: cwd)
        let updates = try await Self.waitForTerminalExit(of: fixture.collector)
        await fixture.harness.flushPendingChunks()
        let streamed = try Self.streamedTerminalText(in: updates)
        let report = try Self.shellRunReport(
            of: try await Self.accumulatedToolCall(of: fixture, id: Self.nestedRunWaitCallId))
        await fixture.close()

        // The disk is the truth (plan.md §20.1): the redirect named a
        // path outside the root set, and nothing is there.
        #expect(!FileManager.default.fileExists(atPath: escaped.path))

        // The refusal reaches the client in band on the terminal stream:
        // the shell's own message names the refused path and carries the
        // kernel's `EPERM`, which is the whole of the refusal text.
        #expect(streamed.contains(Self.sandboxDenialMarker))
        #expect(streamed.contains(escaped.path))

        // The run report the collecting `wait` answered says the same
        // thing in fields: the command RAN to its own end — the sandbox
        // refuses at the kernel, not before the spawn — and it exited
        // non-zero.
        #expect(report["status"] as? String == Self.completedRunStatus)
        #expect(try #require(report["exitCode"] as? Int) != Self.successExitCode)

        // Nothing threw: the turn still ends `end_turn`.
        #expect(ScriptedTurnFixture.idleStopReason(in: turnUpdates) == .endTurn)
    }
}
