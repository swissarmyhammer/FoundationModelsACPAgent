import Foundation
import FoundationModels
import FoundationModelsACPAgent
import FoundationModelsMultitool
import FoundationModelsRouter
import Synchronization

// MARK: - The scripted-model seam (plan.md §20.1)
//
// The injectable `ModelLoader` every tier-2 test drives: no MLX, no
// download, no network, no Apple-silicon gate. It runs in CI at every
// commit.
//
// `FoundationModelsRouterTestSupport` vends no injectable backend — its
// scripted backends are private to Router's own test target — so this
// fixture extends the library's `EchoModel` pattern instead:
//
//   StubModelLoader (ModelLoader) -> ScriptedLLMContainer
//     -> ScriptedSessionBackend (LanguageModelSessionBackend)

/// One step of a scripted turn.
public enum ScriptedTurnStep: Sendable, Equatable {
    /// Streams `text` as one delta.
    case textDelta(String)

    /// Invokes the handed tool named `name` with the fixed
    /// `argumentsJSON`.
    case toolCall(name: String, argumentsJSON: String)

    /// Invokes the handed tool named `name` with the completion token
    /// the step before it answered — the `wait` play that names the run
    /// it collects instead of asking for whatever is still running.
    ///
    /// **Why a scripted turn needs this step.** A `wait` call that names
    /// no token reads a SNAPSHOT of the runs that have not settled yet,
    /// and a run drops out of that snapshot the moment it settles. So a
    /// no-token play collects a run only while the run is still going,
    /// and a run that finished first is gone from it for ever. A play
    /// that NAMES the token reads the mailbox's retained terminal as
    /// well, so it collects the run whether the run is still going or
    /// already finished, and the collection cannot race the run.
    ///
    /// The token is read from the previous step's own answer, because a
    /// script is written before the session mints one.
    case collectingToolCall(name: String)

    /// Throws the real SDK error `failure` names, so a stop-reason test
    /// drives the turn owner's error mapping (plan.md §8.2).
    case fail(ScriptedFailure)

    /// Suspends until the turn's task is cancelled, then throws
    /// `CancellationError`. A cancellation test holds the turn open with
    /// this step and cancels it from the client end (plan.md §8.6).
    case hold

    /// Writes `text` to the file at `path`, and plays no model output.
    ///
    /// A proof uses it to act BETWEEN two model steps, which is the only
    /// place a test can act inside a turn: the wire carries a played call
    /// when the turn's transcript diff goes out, thus nothing of a call is
    /// observable while the next call runs. The file may be a named pipe,
    /// and a write to one releases a run the step before it is holding.
    case writeFile(path: String, text: String)

    /// Ends the turn. Steps after this one are never emitted.
    case endTurn
}

/// The SDK failure a ``ScriptedTurnStep/fail(_:)`` step throws.
///
/// The cases are `Equatable` markers; ``error`` makes the real
/// `LanguageModelError` value — the macOS 27 vocabulary the turn
/// classifier reads — from the public payload initializers.
public enum ScriptedFailure: Sendable, Equatable {
    /// The context size the scripted overflow reports. The value only
    /// satisfies the payload initializer.
    private static let scriptedContextSize = 4096

    /// The token count the scripted overflow reports; larger than
    /// ``scriptedContextSize``, as a real overflow is.
    private static let scriptedTokenCount = 8192

    /// The guardrail refusal, which maps to the `refusal` stop reason.
    case guardrailViolation

    /// The context overflow, which maps to the `max_tokens` stop reason.
    case exceededContextWindow

    /// The real SDK error this failure throws.
    public var error: any Error {
        switch self {
        case .guardrailViolation:
            LanguageModelError.guardrailViolation(
                .init(debugDescription: "scripted guardrail refusal"))
        case .exceededContextWindow:
            LanguageModelError.contextSizeExceeded(
                .init(
                    contextSize: Self.scriptedContextSize,
                    tokenCount: Self.scriptedTokenCount,
                    debugDescription: "scripted context overflow"))
        }
    }
}

/// Records every model prompt the scripted backend receives, so a
/// harness test asserts what the model was given (plan.md §20.1).
public actor PromptRecorder {
    /// The recorded prompts, in arrival order.
    public private(set) var prompts: [String] = []

    /// Creates a recorder that has recorded nothing.
    public init() {}

    /// Records one prompt.
    ///
    /// - Parameter prompt: The prompt the backend received.
    public func record(prompt: String) {
        prompts.append(prompt)
    }
}

/// The failure of a scripted step.
public enum ScriptedModelError: Error, Equatable {
    /// A `toolCall` step named a tool the session was not handed. The
    /// turn fails loudly instead of passing while measuring nothing.
    case unknownTool(String)

    /// A `collectingToolCall` step stood after a step whose answer
    /// carried no completion token, so the play has no run to name. The
    /// turn fails loudly instead of collecting whatever is still
    /// running, which is the snapshot read the step exists to avoid.
    case noRunToCollect
}

/// A session backend that plays a fixed script: text deltas, known
/// tool calls with fixed arguments, and a turn end.
///
/// Every generating call plays the same script from the start.
///
/// The synthesized transcript has the shape a real model session's has,
/// so a recording over it is a recording of a real turn shape (task
/// ^jz016kq):
///
/// - one leading `.instructions` entry, made once and never rewritten,
///   carrying the session instructions and one `Transcript.ToolDefinition`
///   per handed tool;
/// - one `.prompt` entry per generating call, before the play;
/// - a `.toolCalls` entry before each played invocation and a
///   `.toolOutput` entry after it, so Router's transcript diff derives
///   the `toolCall` and `toolStatus` session events for the tier-2
///   projection proofs (plan.md §8.4, §20.1);
/// - one `.response` entry after a play that reached the turn end. A
///   failing or cancelled play appends none, as a real failed turn
///   records none.
///
/// The entries are SDK `Transcript` values with public initializers,
/// never Router recording values.
///
/// A class, not a struct, because `LanguageModelSessionBackend`
/// requires `AnyObject`. The one mutable member is guarded by a
/// `Mutex`, so its `Sendable` conformance stays compiler-checked.
public final class ScriptedSessionBackend: LanguageModelSessionBackend {
    /// The token usage every scripted backend reports, in the pattern
    /// of `EchoSessionBackend`: a constant one/one, so a usage consumer
    /// observes a report.
    private static let scriptedUsage = (input: 1, output: 1)

    /// The prefix of every synthesized SDK tool-call id. The suffix is
    /// the one-based ordinal of the call, so a test addresses the first
    /// scripted call as `scripted-call-1`.
    public static let scriptedCallIdPrefix = "scripted-call-"

    /// The schema name the synthesized structured output segment
    /// declares. The value only satisfies the SDK initializer.
    private static let outputSchemaName = "ScriptedToolOutput"

    /// The field a background run's pending envelope carries its
    /// completion token under, and the field a `wait` call names the run
    /// to collect under. One name serves both, because the envelope is
    /// where the collecting play reads the token it passes back.
    private static let completionTokenField = "completionToken"

    /// The synthesized transcript of one backend: the SDK entries the
    /// played tool calls appended, and how many tool calls played —
    /// the source of the deterministic scripted call ids.
    private struct SynthesizedTranscript {
        /// The appended SDK entries, in append order.
        var entries: [Transcript.Entry] = []

        /// The number of tool calls played so far.
        var playedToolCallCount = 0

        /// The text the newest played tool call answered, or `nil`
        /// before the first call answers. A
        /// ``ScriptedTurnStep/collectingToolCall(name:)`` step reads the
        /// completion token out of it.
        var latestAnswer: String?
    }

    /// The synthesized transcript, guarded for the sync
    /// `transcriptEntries()` read against the async playback append.
    private let synthesized = Mutex(SynthesizedTranscript())

    /// The steps this backend plays, in order.
    private let script: [ScriptedTurnStep]

    /// The tools the session was handed; `toolCall` steps invoke them.
    private let tools: [any Tool]

    /// The session instructions the leading `.instructions` entry
    /// carries, or `nil` when the session was made without any.
    private let instructions: String?

    /// The recorder each received prompt goes to, or `nil` when the
    /// test does not observe the prompt.
    private let recorder: PromptRecorder?

    /// Creates a backend that plays `script` against `tools`.
    ///
    /// - Parameters:
    ///   - script: The steps to play, in order.
    ///   - tools: The tools `toolCall` steps invoke.
    ///   - instructions: The session instructions the leading
    ///     `.instructions` entry carries, or `nil` for none.
    ///   - seededEntries: The transcript a restored session starts from,
    ///     in place of a fresh leading `.instructions` entry. Empty for
    ///     a fresh session.
    ///   - recorder: The recorder each received prompt goes to, or
    ///     `nil` to record nothing.
    public init(
        script: [ScriptedTurnStep],
        tools: [any Tool],
        instructions: String? = nil,
        seededEntries: [Transcript.Entry] = [],
        recorder: PromptRecorder? = nil
    ) {
        self.script = script
        self.tools = tools
        self.instructions = instructions
        self.recorder = recorder
        let opening =
            seededEntries.isEmpty
            ? [Self.instructionsEntry(instructions: instructions, tools: tools)]
            : seededEntries
        synthesized.withLock { $0.entries = opening }
    }

    public func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await playTurn(prompt: prompt) { _ in }
    }

    public func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    public func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let playback = Task {
                do {
                    _ = try await playTurn(prompt: prompt) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in playback.cancel() }
        }
    }

    public func makeFork() -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(
            script: script,
            tools: tools,
            instructions: instructions,
            seededEntries: transcriptEntries(),
            recorder: recorder)
    }

    /// Makes a backend that continues from `transcript`, not from this
    /// backend's own entries.
    ///
    /// Router calls this after a compaction fold, with the folded
    /// transcript. The protocol default ignores `transcript` and forks, so
    /// without this override a fold never reaches the transcript that a
    /// scripted session reports.
    ///
    /// - Parameter transcript: The transcript the new backend starts from.
    /// - Returns: A backend with this script, these tools and `transcript`.
    public func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(
            script: script,
            tools: tools,
            instructions: instructions,
            seededEntries: Array(transcript),
            recorder: recorder)
    }

    public func transcriptEntries() -> [Transcript.Entry] {
        // The SDK entries the played tool calls appended. Router's
        // transcript diff reads them and derives the `toolCall` and
        // `toolStatus` session events, the way it does for a real
        // model session (plan.md §8.4).
        synthesized.withLock { $0.entries }
    }

    public func usageTokenCounts() -> (input: Int, output: Int)? {
        Self.scriptedUsage
    }

    /// Plays one whole turn: records the prompt, appends the turn's
    /// `.prompt` entry, plays the script, and appends the turn's
    /// `.response` entry.
    ///
    /// A play that throws appends no `.response` entry, because a real
    /// model session records none for a turn that never answered.
    ///
    /// - Parameters:
    ///   - prompt: The prompt the turn answers.
    ///   - yield: Receives each text delta, in order.
    /// - Returns: The answer text, the deltas joined in order.
    /// - Throws: Whatever ``playScript(yield:)`` throws.
    private func playTurn(prompt: String, yield: (String) -> Void) async throws -> String {
        await recorder?.record(prompt: prompt)
        appendPromptEntry(prompt: prompt)
        var text = ""
        try await playScript { delta in
            text += delta
            yield(delta)
        }
        appendResponseEntry(text: text)
        return text
    }

    /// The leading `.instructions` entry of a fresh scripted session:
    /// the instructions text, and one tool definition per handed tool.
    ///
    /// The entry is made once, in `init`, and never rewritten. Its
    /// stability across turns is what task ^jz016kq proves.
    ///
    /// - Parameters:
    ///   - instructions: The instructions text, or `nil` for none.
    ///   - tools: The tools the session was handed.
    /// - Returns: The entry.
    private static func instructionsEntry(
        instructions: String?, tools: [any Tool]
    ) -> Transcript.Entry {
        let segments: [Transcript.Segment] =
            instructions.map { [.text(Transcript.TextSegment(content: $0))] } ?? []
        return .instructions(
            Transcript.Instructions(
                segments: segments,
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }))
    }

    /// Appends the `.prompt` entry of one turn.
    ///
    /// - Parameter prompt: The prompt the turn answers.
    private func appendPromptEntry(prompt: String) {
        let entry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))]))
        synthesized.withLock { $0.entries.append(entry) }
    }

    /// Appends the `.response` entry that closes one turn.
    ///
    /// - Parameter text: The answer text the play produced.
    private func appendResponseEntry(text: String) {
        let entry = Transcript.Entry.response(
            Transcript.Response(segments: [.text(Transcript.TextSegment(content: text))]))
        synthesized.withLock { $0.entries.append(entry) }
    }

    /// Plays the script: yields each delta, invokes each scripted tool
    /// call, and stops at the turn end.
    ///
    /// - Parameter yield: Receives each text delta, in order.
    /// - Throws: ``ScriptedModelError/unknownTool(_:)`` for a tool the
    ///   session was not handed, ``ScriptedModelError/noRunToCollect``
    ///   for a collecting play with no token to name, or the invoked
    ///   tool's own error.
    private func playScript(yield: (String) -> Void) async throws {
        for step in script {
            switch step {
            case .textDelta(let text):
                yield(text)
            case .toolCall(let name, let argumentsJSON):
                try await invokeTool(named: name, argumentsJSON: argumentsJSON)
            case .collectingToolCall(let name):
                try await invokeCollectingTool(named: name)
            case .fail(let failure):
                throw failure.error
            case .hold:
                try await Self.holdUntilCancelled()
            case .writeFile(let path, let text):
                try Self.write(text: text, toFileAt: path)
            case .endTurn:
                return
            }
        }
    }

    /// Suspends until the surrounding task is cancelled, then throws
    /// `CancellationError`. A never-yielding stream carries the wait, so
    /// only a cancellation ends the iteration.
    private static func holdUntilCancelled() async throws {
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        for await _ in stream {}
        withExtendedLifetime(continuation) {}
        try Task.checkCancellation()
    }

    /// Writes `text` to the file at `path`.
    ///
    /// The handle is opened for UPDATING, thus `O_RDWR`. A named pipe
    /// opened that way never waits for the other end, so a step that
    /// releases a held run through a pipe cannot hang the turn, and the
    /// close is still the only writer's close, thus the reading run sees
    /// the end of the stream. A path that holds no file yet is made.
    ///
    /// - Parameters:
    ///   - text: The text to write.
    ///   - path: The file to write it to.
    /// - Throws: The write error.
    private static func write(text: String, toFileAt path: String) throws {
        guard let handle = FileHandle(forUpdatingAtPath: path) else {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// Invokes the handed tool `name` with the fixed arguments, and
    /// appends the SDK transcript entries a real model session records
    /// around a tool call: `.toolCalls` before the invocation, and
    /// `.toolOutput` after it. Router's transcript diff derives the
    /// `toolCall` and `toolStatus` session events from them.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to invoke.
    ///   - argumentsJSON: The fixed arguments, as JSON.
    /// - Throws: ``ScriptedModelError/unknownTool(_:)`` when no handed
    ///   tool has `name`; otherwise the tool's own error.
    private func invokeTool(named name: String, argumentsJSON: String) async throws {
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw ScriptedModelError.unknownTool(name)
        }
        let content = try GeneratedContent(json: argumentsJSON)
        let callId = appendToolCallsEntry(name: name, arguments: content)
        let output = try await ToolInvoker.invoke(tool, content: content)
        appendToolOutputEntry(callId: callId, name: name, output: output)
        synthesized.withLock { $0.latestAnswer = output as? String }
    }

    /// Invokes the handed tool `name` with the completion token the
    /// previous step answered, so the play names the run it collects.
    ///
    /// - Parameter name: The name of the tool to invoke.
    /// - Throws: ``ScriptedModelError/noRunToCollect`` when the previous
    ///   step's answer carries no completion token; otherwise whatever
    ///   ``invokeTool(named:argumentsJSON:)`` throws.
    private func invokeCollectingTool(named name: String) async throws {
        guard let token = latestCompletionToken() else {
            throw ScriptedModelError.noRunToCollect
        }
        try await invokeTool(
            named: name, argumentsJSON: try Self.argumentsJSON(collecting: token))
    }

    /// The completion token the newest played call answered.
    ///
    /// - Returns: The token, or `nil` when no call has answered yet and
    ///   when the newest answer is not an object carrying one.
    private func latestCompletionToken() -> String? {
        guard let answer = synthesized.withLock({ $0.latestAnswer }) else { return nil }
        let decoded = try? JSONSerialization.jsonObject(with: Data(answer.utf8))
        return (decoded as? [String: Any])?[Self.completionTokenField] as? String
    }

    /// The arguments of a collecting play: the one run to wait for.
    ///
    /// - Parameter token: The completion token to name.
    /// - Returns: The arguments, as JSON.
    /// - Throws: The encoding error.
    private static func argumentsJSON(collecting token: String) throws -> String {
        let encoded = try JSONEncoder().encode([completionTokenField: token])
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Appends the `.toolCalls` entry of one played call and mints the
    /// call's deterministic id.
    ///
    /// - Parameters:
    ///   - name: The invoked tool's name.
    ///   - arguments: The call's arguments.
    /// - Returns: The minted scripted call id.
    private func appendToolCallsEntry(name: String, arguments: GeneratedContent) -> String {
        synthesized.withLock { state in
            state.playedToolCallCount += 1
            let callId = Self.scriptedCallIdPrefix + String(state.playedToolCallCount)
            state.entries.append(
                .toolCalls(
                    Transcript.ToolCalls(
                        id: callId + "-batch",
                        [Transcript.ToolCall(id: callId, toolName: name, arguments: arguments)])))
            return callId
        }
    }

    /// Appends the `.toolOutput` entry that answers one played call.
    ///
    /// The output rides as a structured segment when the value converts
    /// to `GeneratedContent` — every session-tool output is a `String`,
    /// which does — so the projection's `rawOutput` reads the real
    /// value. Any other output degrades to a text segment.
    ///
    /// - Parameters:
    ///   - callId: The scripted call id the output answers.
    ///   - name: The invoked tool's name.
    ///   - output: The value the tool returned.
    private func appendToolOutputEntry(callId: String, name: String, output: Any) {
        let segment: Transcript.Segment
        if let convertible = output as? any ConvertibleToGeneratedContent {
            segment = .structure(
                Transcript.StructuredSegment(
                    id: callId + "-output",
                    schemaName: Self.outputSchemaName,
                    content: convertible.generatedContent))
        } else {
            segment = .text(Transcript.TextSegment(content: String(describing: output)))
        }
        synthesized.withLock { state in
            state.entries.append(
                .toolOutput(
                    Transcript.ToolOutput(id: callId, toolName: name, segments: [segment])))
        }
    }
}

/// A resident model whose every session plays the same script.
///
/// All four factories are written out on purpose, like
/// `EchoLLMContainer`: the public default of
/// `makeSession(instructions:tools:)` DROPS `tools`, and a scripted
/// tool call needs them.
public struct ScriptedLLMContainer: LoadedLLMContainer {
    /// The counter of a model with no tokenizer: one token per character.
    public var tokenCounter: any TokenCounter { CharacterCountTokenCounter() }

    /// The script every session plays.
    public let script: [ScriptedTurnStep]

    /// The recorder each session's prompts go to, or `nil` to record
    /// nothing.
    public var recorder: PromptRecorder?

    /// Creates a container whose every session plays `script`.
    ///
    /// - Parameters:
    ///   - script: The script every session plays.
    ///   - recorder: The recorder each session's prompts go to, or `nil`
    ///     (the default) to record nothing.
    public init(script: [ScriptedTurnStep], recorder: PromptRecorder? = nil) {
        self.script = script
        self.recorder = recorder
    }

    public func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(
            script: script, tools: [], instructions: instructions, recorder: recorder)
    }

    public func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(
            script: script, tools: tools, instructions: instructions, recorder: recorder)
    }

    public func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(
            script: script, tools: [], seededEntries: Array(transcript), recorder: recorder)
    }

    public func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(
            script: script, tools: tools, seededEntries: Array(transcript), recorder: recorder)
    }
}

/// Makes a loader whose LLM containers play `script`.
///
/// It reuses ``StubModelLoader`` — the injectable seam the stub profile
/// fixtures already have — so a scripted test downloads nothing and
/// loads nothing.
///
/// - Parameters:
///   - script: The steps every session plays.
///   - recorder: The recorder each received prompt goes to, or `nil`
///     to record nothing.
/// - Returns: The loader to inject.
public func makeScriptedModelLoader(
    script: [ScriptedTurnStep], recorder: PromptRecorder? = nil
) -> StubModelLoader {
    var loader = StubModelLoader()
    loader.makeLLMContainer = { _ in ScriptedLLMContainer(script: script, recorder: recorder) }
    return loader
}
