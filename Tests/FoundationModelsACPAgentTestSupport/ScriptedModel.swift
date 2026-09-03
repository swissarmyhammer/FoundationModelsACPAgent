import Foundation
import FoundationModels
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
// fixture extends the local `StubProfileFixtures.swift` pattern instead:
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

    /// Throws the real SDK error `failure` names, so a stop-reason test
    /// drives the turn owner's error mapping (plan.md §8.2).
    case fail(ScriptedFailure)

    /// Suspends until the turn's task is cancelled, then throws
    /// `CancellationError`. A cancellation test holds the turn open with
    /// this step and cancels it from the client end (plan.md §8.6).
    case hold

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
    public func record(_ prompt: String) {
        prompts.append(prompt)
    }
}

/// The failure of a scripted step.
public enum ScriptedModelError: Error, Equatable {
    /// A `toolCall` step named a tool the session was not handed. The
    /// turn fails loudly instead of passing while measuring nothing.
    case unknownTool(String)
}

/// A session backend that plays a fixed script: text deltas, known
/// tool calls with fixed arguments, and a turn end.
///
/// Every generating call plays the same script from the start.
///
/// Each `toolCall` step also appends the SDK transcript entries a real
/// model session would record — a `.toolCalls` entry before the
/// invocation, and a `.toolOutput` entry after it — so Router's
/// transcript diff derives the `toolCall` and `toolStatus` session
/// events for the tier-2 projection proofs (plan.md §8.4, §20.1). The
/// entries are SDK `Transcript` values with public initializers, never
/// Router recording values.
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
    }

    /// The synthesized transcript, guarded for the sync
    /// `transcriptEntries()` read against the async playback append.
    private let synthesized = Mutex(SynthesizedTranscript())

    /// The steps this backend plays, in order.
    private let script: [ScriptedTurnStep]

    /// The tools the session was handed; `toolCall` steps invoke them.
    private let tools: [any Tool]

    /// The recorder each received prompt goes to, or `nil` when the
    /// test does not observe the prompt.
    private let recorder: PromptRecorder?

    /// Creates a backend that plays `script` against `tools`.
    ///
    /// - Parameters:
    ///   - script: The steps to play, in order.
    ///   - tools: The tools `toolCall` steps invoke.
    ///   - recorder: The recorder each received prompt goes to, or
    ///     `nil` to record nothing.
    public init(script: [ScriptedTurnStep], tools: [any Tool], recorder: PromptRecorder? = nil) {
        self.script = script
        self.tools = tools
        self.recorder = recorder
    }

    public func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        await recorder?.record(prompt)
        var text = ""
        try await playScript { text += $0 }
        return text
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
                    await recorder?.record(prompt)
                    try await playScript { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in playback.cancel() }
        }
    }

    public func makeFork() -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: tools, recorder: recorder)
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

    /// Plays the script: yields each delta, invokes each scripted tool
    /// call, and stops at the turn end.
    ///
    /// - Parameter yield: Receives each text delta, in order.
    /// - Throws: ``ScriptedModelError/unknownTool(_:)`` for a tool the
    ///   session was not handed, or the invoked tool's own error.
    private func playScript(yield: (String) -> Void) async throws {
        for step in script {
            switch step {
            case .textDelta(let text):
                yield(text)
            case .toolCall(let name, let argumentsJSON):
                try await invokeTool(named: name, argumentsJSON: argumentsJSON)
            case .fail(let failure):
                throw failure.error
            case .hold:
                try await Self.holdUntilCancelled()
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
        ScriptedSessionBackend(script: script, tools: [], recorder: recorder)
    }

    public func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: tools, recorder: recorder)
    }

    public func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: [], recorder: recorder)
    }

    public func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: tools, recorder: recorder)
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
