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

/// One step of a scripted pass.
public enum ScriptedPassStep: Sendable, Equatable {
    /// Streams `text` as one delta.
    case textDelta(String)

    /// Adds `text` to the `.reasoning` entry of the pass. The first
    /// reasoning step of a pass makes that entry, and each reasoning step
    /// after it makes the text of the same entry longer. A proof that
    /// must show a call in flight to Router's repetition watch plays its
    /// reasoning with this step (task ^k51h6bb).
    case reasoning(String)

    /// Invokes the handed tool named `name` with the fixed
    /// `argumentsJSON`.
    case toolCall(name: String, argumentsJSON: String)

    /// Throws the real SDK error `failure` names, so a stop-reason test
    /// drives the prompt owner's error mapping (plan.md §8.2).
    case fail(ScriptedFailure)

    /// Suspends until the pass's task is cancelled, then throws
    /// `CancellationError`. A cancellation test holds the prompt open with
    /// this step and cancels it from the client end (plan.md §8.6).
    case hold

    /// Suspends until the test calls ``ScriptedHold/release()`` on the
    /// hold, and then plays the next step. When the pass's task is
    /// cancelled first, it throws `CancellationError`, as ``hold`` does.
    case holdUntilReleased(ScriptedHold)

    /// Writes `text` to the file at `path`, and plays no model output.
    ///
    /// A proof uses it to act BETWEEN two model steps, which is the only
    /// place a test can act inside a pass: the wire carries a played call
    /// when the pass's transcript diff goes out, thus nothing of a call is
    /// observable while the next call runs. The file may be a named pipe,
    /// and a write to one releases a run the step before it is holding.
    case writeFile(path: String, text: String)

    /// Plays `steps` in place of this step when the prompt of the pass
    /// contains `marker`, and plays nothing when it does not. An
    /// ``endPass`` in `steps` ends the whole pass.
    ///
    /// Each pass plays the same script. A proof uses this step to give the
    /// passes of one script different plays: each caller prompt carries its
    /// own marker, and an answer that mail starts carries no marker.
    indirect case onPrompt(containing: String, play: [ScriptedPassStep])

    /// Ends the pass. Steps after this one are never emitted.
    case endPass
}

/// The SDK failure a ``ScriptedPassStep/fail(_:)`` step throws.
///
/// The cases are `Equatable` markers; ``error`` makes the real
/// `LanguageModelError` value — the macOS 27 vocabulary the prompt
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
    /// pass fails loudly instead of passing while measuring nothing.
    case unknownTool(String)
}

/// A session backend that plays a fixed script: text deltas, known
/// tool calls with fixed arguments, and a pass end.
///
/// Every generating call plays the same script from the start.
///
/// The synthesized transcript has the shape a real model session's has,
/// so a recording over it is a recording of a real pass shape (task
/// ^jz016kq):
///
/// - one leading `.instructions` entry, made once and never rewritten,
///   carrying the session instructions and one `Transcript.ToolDefinition`
///   per handed tool;
/// - one `.prompt` entry per generating call, before the play;
/// - one `.reasoning` entry in a pass that plays a
///   ``ScriptedPassStep/reasoning(_:)`` step. Each such step makes its text
///   longer, and ``transcriptUpdates()`` shows each change while the pass
///   runs, as the live SDK session does (task ^k51h6bb);
/// - a `.toolCalls` entry before each played invocation and a
///   `.toolOutput` entry after it, so Router's transcript diff derives
///   the `toolCall` and `toolStatus` session events for the tier-2
///   projection proofs (plan.md §8.4, §20.1);
/// - one `.response` entry after a play that reached the pass end. A
///   failing or cancelled play appends none, as a real failed pass
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

    /// The synthesized transcript of one backend: the SDK entries the
    /// played tool calls appended, and how many tool calls played —
    /// the source of the deterministic scripted call ids.
    private struct SynthesizedTranscript {
        /// The appended SDK entries, in append order.
        var entries: [Transcript.Entry] = []

        /// The number of tool calls played so far.
        var playedToolCallCount = 0

        /// The `.reasoning` entry of the pass in flight, or `nil` before
        /// the first reasoning step of the pass.
        var liveReasoning: LiveReasoning?

        /// The continuation of each open ``transcriptUpdates()`` stream, by
        /// the key of the stream.
        var observers: [Int: AsyncStream<[Transcript.Entry]>.Continuation] = [:]

        /// The key of the next ``transcriptUpdates()`` stream.
        var nextObserverKey = 0
    }

    /// The `.reasoning` entry that the reasoning steps of one pass make
    /// longer: its place in the entries, its stable id, and its text.
    private struct LiveReasoning {
        /// The index of the entry in ``SynthesizedTranscript/entries``.
        let index: Int

        /// The id of the entry. It stays the same while the text grows, as
        /// the id of a live SDK entry does.
        let id: String

        /// The text of the entry so far.
        var text: String
    }

    /// The synthesized transcript, guarded for the sync
    /// `transcriptEntries()` read against the async playback append.
    private let synthesized = Mutex(SynthesizedTranscript())

    /// The steps this backend plays, in order.
    private let script: [ScriptedPassStep]

    /// The tools the session was handed; `toolCall` steps invoke them.
    private let tools: [any Tool]

    /// The session instructions the leading `.instructions` entry
    /// carries, or `nil` when the session was made without any.
    private let instructions: String?

    /// The recorder each received prompt goes to, or `nil` when the
    /// test does not observe the prompt.
    private let recorder: PromptRecorder?

    /// The generation queue of the pool entry of this backend's model, or
    /// `nil`. When it is set, the Router session submits each generating
    /// call of this backend to it as one item, so one play of the script
    /// waits for its place in the queue.
    public let generationQueue: GenerationQueue?

    /// The counter each play of the script is counted on, or `nil` when
    /// the test does not count the passes.
    private let passCounter: ScriptedPassCounter?

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
    ///   - generationQueue: The generation queue of the pool entry, or
    ///     `nil` (the default) for a backend whose calls run directly.
    ///   - passCounter: The counter of the plays, or `nil` (the default)
    ///     to count nothing.
    public init(
        script: [ScriptedPassStep],
        tools: [any Tool],
        instructions: String? = nil,
        seededEntries: [Transcript.Entry] = [],
        recorder: PromptRecorder? = nil,
        generationQueue: GenerationQueue? = nil,
        passCounter: ScriptedPassCounter? = nil
    ) {
        self.script = script
        self.tools = tools
        self.instructions = instructions
        self.recorder = recorder
        self.generationQueue = generationQueue
        self.passCounter = passCounter
        let opening =
            seededEntries.isEmpty
            ? [Self.instructionsEntry(instructions: instructions, tools: tools)]
            : seededEntries
        synthesized.withLock { $0.entries = opening }
    }

    public func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await playPass(prompt: prompt) { _ in }
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
                    _ = try await playPass(prompt: prompt) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in playback.cancel() }
        }
    }

    public func makeFork() -> any LanguageModelSessionBackend {
        makeSibling(seededEntries: transcriptEntries())
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
        makeSibling(seededEntries: Array(transcript))
    }

    /// Makes a backend with this script, these tools, this recorder, this
    /// queue and this counter, that starts from `seededEntries`. A fork and
    /// a replaced transcript thus stay on the queue of the model.
    ///
    /// - Parameter seededEntries: The transcript the new backend starts from.
    /// - Returns: The new backend.
    private func makeSibling(seededEntries: [Transcript.Entry]) -> ScriptedSessionBackend {
        ScriptedSessionBackend(
            script: script,
            tools: tools,
            instructions: instructions,
            seededEntries: seededEntries,
            recorder: recorder,
            generationQueue: generationQueue,
            passCounter: passCounter)
    }

    public func transcriptEntries() -> [Transcript.Entry] {
        // The SDK entries the played tool calls appended. Router's
        // transcript diff reads them and derives the `toolCall` and
        // `toolStatus` session events, the way it does for a real
        // model session (plan.md §8.4).
        synthesized.withLock { $0.entries }
    }

    /// The transcript of this backend now, and again after each change of
    /// it, while the stream is read (task ^k51h6bb).
    ///
    /// Router's repetition watch reads this stream while a call is in
    /// flight. A backend that keeps the protocol default gives no value,
    /// and Router does not watch its calls. Values that come faster than
    /// the reader reads merge into the newest one, as the contract permits.
    ///
    /// - Returns: The stream of the transcript.
    public func transcriptUpdates() -> AsyncStream<[Transcript.Entry]> {
        let (stream, continuation) = AsyncStream<[Transcript.Entry]>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let key = synthesized.withLock { state in
            let key = state.nextObserverKey
            state.nextObserverKey += 1
            state.observers[key] = continuation
            continuation.yield(state.entries)
            return key
        }
        continuation.onTermination = { [weak self] _ in
            self?.synthesized.withLock { state in
                _ = state.observers.removeValue(forKey: key)
            }
        }
        return stream
    }

    public func usageTokenCounts() -> (input: Int, output: Int)? {
        Self.scriptedUsage
    }

    /// Plays one whole pass: records the prompt, appends the pass's
    /// `.prompt` entry, plays the script, and appends the pass's
    /// `.response` entry.
    ///
    /// A play that throws appends no `.response` entry, because a real
    /// model session records none for a pass that never answered.
    ///
    /// The pass counter counts the play from its start to its end, also
    /// when the play throws.
    ///
    /// - Parameters:
    ///   - prompt: The prompt the pass answers.
    ///   - yield: Receives each text delta, in order.
    /// - Returns: The answer text, the deltas joined in order.
    /// - Throws: Whatever ``play(_:prompt:yield:)`` throws.
    private func playPass(prompt: String, yield: (String) -> Void) async throws -> String {
        passCounter?.passDidStart()
        defer { passCounter?.passDidEnd() }
        await recorder?.record(prompt: prompt)
        appendPromptEntry(prompt: prompt)
        var text = ""
        _ = try await play(script, prompt: prompt) { delta in
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
    /// stability across passes is what task ^jz016kq proves.
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

    /// Appends the `.prompt` entry of one pass.
    ///
    /// - Parameter prompt: The prompt the pass answers.
    private func appendPromptEntry(prompt: String) {
        let entry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))]))
        changeTranscript { state in
            state.entries.append(entry)
            state.liveReasoning = nil
        }
    }

    /// Changes the synthesized transcript with `change`, and gives the
    /// changed entries to each open ``transcriptUpdates()`` stream.
    ///
    /// - Parameter change: The change to make, under the lock.
    /// - Returns: What `change` returns.
    private func changeTranscript<Result: Sendable>(
        _ change: (inout SynthesizedTranscript) -> Result
    ) -> Result {
        synthesized.withLock { state in
            let result = change(&state)
            for observer in state.observers.values {
                observer.yield(state.entries)
            }
            return result
        }
    }

    /// Adds `text` to the `.reasoning` entry of the pass in flight, and
    /// makes that entry when the pass has none yet.
    ///
    /// - Parameter text: The reasoning text to add.
    private func appendReasoning(_ text: String) {
        changeTranscript { state in
            var reasoning =
                state.liveReasoning
                ?? LiveReasoning(index: state.entries.count, id: UUID().uuidString, text: "")
            reasoning.text += text
            let entry = Transcript.Entry.reasoning(
                Transcript.Reasoning(
                    id: reasoning.id,
                    segments: [.text(Transcript.TextSegment(content: reasoning.text))],
                    signature: nil))
            if state.entries.indices.contains(reasoning.index) {
                state.entries[reasoning.index] = entry
            } else {
                state.entries.append(entry)
            }
            state.liveReasoning = reasoning
        }
    }

    /// Appends the `.response` entry that closes one pass.
    ///
    /// - Parameter text: The answer text the play produced.
    private func appendResponseEntry(text: String) {
        let entry = Transcript.Entry.response(
            Transcript.Response(segments: [.text(Transcript.TextSegment(content: text))]))
        changeTranscript { $0.entries.append(entry) }
    }

    /// Plays `steps`: yields each delta, invokes each scripted tool call,
    /// plays the steps of each ``ScriptedPassStep/onPrompt(containing:play:)``
    /// whose marker `prompt` contains, and stops at the pass end.
    ///
    /// - Parameters:
    ///   - steps: The steps to play, in order.
    ///   - prompt: The prompt the pass answers.
    ///   - yield: Receives each text delta, in order.
    /// - Returns: `true` when an ``ScriptedPassStep/endPass`` step ended
    ///   the play, and `false` when the play ran out of steps.
    /// - Throws: ``ScriptedModelError/unknownTool(_:)`` for a tool the
    ///   session was not handed, or the invoked tool's own error.
    private func play(
        _ steps: [ScriptedPassStep], prompt: String, yield: (String) -> Void
    ) async throws -> Bool {
        for step in steps {
            switch step {
            case .textDelta(let text):
                yield(text)
            case .reasoning(let text):
                appendReasoning(text)
            case .toolCall(let name, let argumentsJSON):
                try await invokeTool(named: name, argumentsJSON: argumentsJSON)
            case .fail(let failure):
                throw failure.error
            case .hold:
                try await Self.holdUntilCancelled()
            case .holdUntilReleased(let hold):
                try await hold.waitForRelease()
            case .writeFile(let path, let text):
                try Self.write(text: text, toFileAt: path)
            case .onPrompt(let marker, let branch):
                if prompt.contains(marker), try await play(branch, prompt: prompt, yield: yield) {
                    return true
                }
            case .endPass:
                return true
            }
        }
        return false
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
    /// releases a held run through a pipe cannot hang the pass, and the
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
    }

    /// Appends the `.toolCalls` entry of one played call and mints the
    /// call's deterministic id.
    ///
    /// - Parameters:
    ///   - name: The invoked tool's name.
    ///   - arguments: The call's arguments.
    /// - Returns: The minted scripted call id.
    private func appendToolCallsEntry(name: String, arguments: GeneratedContent) -> String {
        changeTranscript { state in
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
        changeTranscript { state in
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
    public let script: [ScriptedPassStep]

    /// The recorder each session's prompts go to, or `nil` to record
    /// nothing.
    public var recorder: PromptRecorder?

    /// The counter of the passes of this model, or `nil`. A container with
    /// a counter is the queued scripted model: its backends name the
    /// generation queue of the pool entry.
    public let passCounter: ScriptedPassCounter?

    /// The generation queue of the pool entry that each backend names, or
    /// `nil` before the Router gives one.
    private var generationQueue: GenerationQueue?

    /// Creates a container whose every session plays `script`.
    ///
    /// - Parameters:
    ///   - script: The script every session plays.
    ///   - recorder: The recorder each session's prompts go to, or `nil`
    ///     (the default) to record nothing.
    ///   - passCounter: The counter of the passes, or `nil` (the default)
    ///     for a model whose calls run directly, with no queue.
    public init(
        script: [ScriptedPassStep], recorder: PromptRecorder? = nil,
        passCounter: ScriptedPassCounter? = nil
    ) {
        self.script = script
        self.recorder = recorder
        self.passCounter = passCounter
    }

    /// Gives a copy of this container whose backends name `queue`, the
    /// generation queue of the pool entry, when this container has a pass
    /// counter. The Router calls it one time for each hold. A container
    /// with no counter keeps the protocol default: no queue, and each call
    /// runs directly.
    ///
    /// - Parameter queue: The generation queue of the pool entry.
    /// - Returns: The container whose backends name `queue`, or this
    ///   container when it has no pass counter.
    public func submitting(to queue: GenerationQueue) -> any LoadedLLMContainer {
        guard let passCounter else { return self }
        passCounter.adopt(queue: queue)
        var copy = self
        copy.generationQueue = queue
        return copy
    }

    public func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeBackend(tools: [], instructions: instructions)
    }

    public func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        makeBackend(tools: tools, instructions: instructions)
    }

    public func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeBackend(tools: [], seededEntries: Array(transcript))
    }

    public func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        makeBackend(tools: tools, seededEntries: Array(transcript))
    }

    /// Makes one backend of this container: this script, this recorder,
    /// this queue and this counter.
    ///
    /// - Parameters:
    ///   - tools: The tools of the session.
    ///   - instructions: The session instructions, or `nil` for none.
    ///   - seededEntries: The transcript a restored session starts from,
    ///     or empty for a fresh session.
    /// - Returns: The backend.
    private func makeBackend(
        tools: [any Tool], instructions: String? = nil, seededEntries: [Transcript.Entry] = []
    ) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(
            script: script,
            tools: tools,
            instructions: instructions,
            seededEntries: seededEntries,
            recorder: recorder,
            generationQueue: generationQueue,
            passCounter: passCounter)
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
    script: [ScriptedPassStep], recorder: PromptRecorder? = nil
) -> StubModelLoader {
    var loader = StubModelLoader()
    loader.makeLLMContainer = { _ in ScriptedLLMContainer(script: script, recorder: recorder) }
    return loader
}
