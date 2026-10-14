import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import FoundationModelsRouter

/// The no-op check of a tool call (task ^ys32tj4): the check marks a
/// `runCode` call whose snippet calls no `tools.*` verb, and each session
/// that the agent vends or restores gets the check.
///
/// While an operation of a session is pending, Router does not run the body
/// of a marked call. The result of the pending operation is injected into
/// the session as a new message later, and that message starts the model
/// again.
@Suite struct NoOpToolCallTests {
    /// A snippet that calls no `tools.*` verb. SWE-bench run `no-otel-1011`
    /// recorded this snippet while a call was pending.
    static let placeholderSnippet = #"return "end 11";"#

    /// A snippet that calls a `tools.*` verb.
    static let toolsVerbSnippet = #"return await tools.files.read({ path: "README.md" });"#

    /// The name of a tool that is not `runCode`.
    static let otherToolName = "skills"

    /// The prompt that records the first answer of a session.
    static let recordPrompt = "record the first answer"

    /// The prompt whose answer starts the pending operation and then calls
    /// `runCode` with ``placeholderSnippet``.
    static let callerPrompt = "start the job, then wait"

    /// The text that ends each scripted answer.
    static let answerText = "done"

    /// The script of each session of a test.
    ///
    /// The answer to ``callerPrompt`` calls ``PendingJobTool`` and then
    /// `runCode` with ``placeholderSnippet``. The answer to each other prompt
    /// only gives ``answerText``.
    static let script: [ScriptedPassStep] = [
        .onPrompt(
            containing: callerPrompt,
            play: [
                .toolCall(name: PendingJobTool.toolName, argumentsJSON: "{}"),
                .toolCall(name: NoOpToolCall.runCodeToolName, argumentsJSON: runCodeArguments(placeholderSnippet)),
            ]),
        .textDelta(answerText),
        .endPass,
    ]

    /// The JSON arguments of a `runCode` call.
    ///
    /// - Parameter snippet: The snippet, with no backslash.
    /// - Returns: The JSON object text.
    static func runCodeArguments(_ snippet: String) -> String {
        let escaped = snippet.replacingOccurrences(of: #"""#, with: #"\""#)
        return #"{"code": ""# + escaped + #""}"#
    }

    /// The arguments of a call, from its JSON text.
    ///
    /// - Parameter json: The JSON object text.
    /// - Returns: The generated content.
    /// - Throws: Whatever the JSON parse throws.
    static func arguments(_ json: String) throws -> GeneratedContent {
        try GeneratedContent(json: json)
    }

    // MARK: The check

    @Test func aRunCodeCallThatOnlyReturnsAPlaceholderIsANoOp() throws {
        let arguments = try Self.arguments(Self.runCodeArguments(Self.placeholderSnippet))

        #expect(NoOpToolCall.check(NoOpToolCall.runCodeToolName, arguments))
    }

    @Test func aRunCodeCallOfAToolsVerbIsNotANoOp() throws {
        let arguments = try Self.arguments(Self.runCodeArguments(Self.toolsVerbSnippet))

        #expect(!NoOpToolCall.check(NoOpToolCall.runCodeToolName, arguments))
    }

    @Test func aCallOfAnotherToolIsNotANoOp() throws {
        let arguments = try Self.arguments(Self.runCodeArguments(Self.placeholderSnippet))

        #expect(!NoOpToolCall.check(Self.otherToolName, arguments))
    }

    @Test func aRunCodeCallWithNoSnippetIsNotANoOp() throws {
        let arguments = try Self.arguments(#"{"op": "use skill"}"#)

        #expect(!NoOpToolCall.check(NoOpToolCall.runCodeToolName, arguments))
    }

    // MARK: The sessions the agent vends and restores

    /// A new session from `makeBudgetedSession`, the door of `session/new`,
    /// does not run a no-op `runCode` call while an operation is pending.
    @Test
    func aNewSessionDoesNotRunANoOpCallWhileAnOperationIsPending() async throws {
        let fixture = try await NoOpSessionFixture.make(label: "NoOpToolCallTests-new")
        defer { fixture.removeDirectory() }
        let session = fixture.makeSession()

        _ = try await session.respond(to: Self.callerPrompt)
        await session.close()

        #expect(fixture.runCode.runCount == 0)
    }

    /// A session from `restoreSessionWithHostChecks`, the door of
    /// `session/resume`, does not run a no-op `runCode` call while an
    /// operation is pending.
    @Test
    func aResumedSessionDoesNotRunANoOpCallWhileAnOperationIsPending() async throws {
        let fixture = try await NoOpSessionFixture.make(label: "NoOpToolCallTests-resume")
        defer { fixture.removeDirectory() }
        let recorded = fixture.makeSession()
        _ = try await recorded.respond(to: Self.recordPrompt)
        await recorded.close()

        let restored = try await fixture.profile.standard.restoreSessionWithHostChecks(
            id: recorded.id, recordingRoot: fixture.recordingRoot, instructions: NoOpSessionFixture.instructions,
            tools: fixture.tools)
        _ = try await restored.session.respond(to: Self.callerPrompt)
        await restored.session.close()

        #expect(fixture.runCode.runCount == 0)
    }
}

/// The profile, the tools and the directory of one session test of
/// ``NoOpToolCallTests``.
struct NoOpSessionFixture {
    /// The instructions of each session.
    static let instructions = "Do the task."

    /// The temporary directory of the test.
    let directory: URL

    /// The profile whose model plays ``NoOpToolCallTests/script``.
    let profile: LanguageModelProfile

    /// The `runCode` stub, which counts its runs.
    let runCode: CountingRunCodeTool

    /// The tools of each session: the pending job and the `runCode` stub.
    ///
    /// The live backend of Router gives the model each tool in Router's
    /// `SessionCheckedTool`, which asks the check of the session before the
    /// tool body runs. The scripted backend calls the tools it gets as they
    /// are, so the fixture gives it the `runCode` stub in that decorator.
    var tools: [any FoundationModels.Tool] { [PendingJobTool(), runCode.sessionChecked] }

    /// The recording root of each session, and of the router.
    var recordingRoot: URL { Self.recordingRoot(in: directory) }

    /// The recording root under `directory`.
    ///
    /// - Parameter directory: The temporary directory of the test.
    /// - Returns: The recording root.
    static func recordingRoot(in directory: URL) -> URL {
        directory.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Makes the fixture in a new temporary directory.
    ///
    /// - Parameter label: The start of the name of the directory.
    /// - Returns: The fixture.
    /// - Throws: Whatever the directory or the profile throws.
    static func make(label: String) async throws -> NoOpSessionFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = try await makeStubProfile(
            cacheDirectory: directory.appendingPathComponent("cache", isDirectory: true),
            recordingsDirectory: recordingRoot(in: directory),
            loader: makeScriptedModelLoader(script: NoOpToolCallTests.script))
        return NoOpSessionFixture(directory: directory, profile: profile, runCode: CountingRunCodeTool())
    }

    /// Vends one session through `makeBudgetedSession`.
    ///
    /// - Returns: The session.
    func makeSession() -> any RoutedSession {
        profile.standard.makeBudgetedSession(
            instructions: Self.instructions,
            workingDirectory: directory,
            recordingRoot: recordingRoot,
            tools: tools,
            compaction: CompactionConfiguration(),
            repetition: RepetitionConfiguration(),
            inlineSettleGrace: CatalogContext.defaultInlineSettleGrace)
    }

    /// Removes the temporary directory.
    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A background tool whose call answers with its pending envelope at once,
/// and whose run does not settle while the test runs: an operation that stays
/// pending.
struct PendingJobTool: FoundationModels.Tool, BackgroundTool {
    /// The wire arguments; the tool reads nothing from them.
    @Generable
    struct Arguments {}

    /// The name of the tool.
    static let toolName = "start_job"

    let name = Self.toolName

    let description = "a scripted tool whose run stays pending"

    var mount: ToolMount? { ToolMount(mode: .background) }

    var inlineSettleGrace: TimeInterval { 0 }

    func call(arguments: Arguments) async throws -> String {
        // The run stays pending: only the close of the session, which
        // cancels the run, ends it.
        try await waitForCancellation()
        return Self.toolName
    }
}

/// A stub of the `runCode` tool that counts the runs of its body.
struct CountingRunCodeTool: FoundationModels.Tool {
    /// The arguments of `runCode`: the snippet.
    @Generable
    struct Arguments {
        /// The JavaScript snippet.
        var code: String
    }

    /// The count of the runs, shared by each copy of the tool.
    private let runs = CallCounter()

    let name = NoOpToolCall.runCodeToolName

    let description = "a stub of runCode that counts its runs"

    /// The count of the runs of the body.
    var runCount: Int { runs.count }

    func call(arguments: Arguments) async throws -> String {
        runs.record()
        return arguments.code
    }
}
