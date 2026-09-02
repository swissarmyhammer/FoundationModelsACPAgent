import Foundation
import FoundationModels
import FoundationModelsMultitool
import FoundationModelsRouter

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
enum ScriptedTurnStep: Sendable, Equatable {
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
enum ScriptedFailure: Sendable, Equatable {
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
    var error: any Error {
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

/// The failure of a scripted step.
enum ScriptedModelError: Error, Equatable {
    /// A `toolCall` step named a tool the session was not handed. The
    /// turn fails loudly instead of passing while measuring nothing.
    case unknownTool(String)
}

/// A session backend that plays a fixed script: text deltas, known
/// tool calls with fixed arguments, and a turn end.
///
/// Every generating call plays the same script from the start; the
/// backend keeps no call state.
///
/// A class, not a struct, because `LanguageModelSessionBackend`
/// requires `AnyObject`. It holds only immutable state, so its
/// `Sendable` conformance is compiler-checked.
final class ScriptedSessionBackend: LanguageModelSessionBackend {
    /// The token usage every scripted backend reports, in the pattern
    /// of `EchoSessionBackend`: a constant one/one, so a usage consumer
    /// observes a report.
    private static let scriptedUsage = (input: 1, output: 1)

    /// The steps this backend plays, in order.
    private let script: [ScriptedTurnStep]

    /// The tools the session was handed; `toolCall` steps invoke them.
    private let tools: [any Tool]

    /// Creates a backend that plays `script` against `tools`.
    ///
    /// - Parameters:
    ///   - script: The steps to play, in order.
    ///   - tools: The tools `toolCall` steps invoke.
    init(script: [ScriptedTurnStep], tools: [any Tool]) {
        self.script = script
        self.tools = tools
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        var text = ""
        try await playScript { text += $0 }
        return text
    }

    func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let playback = Task {
                do {
                    try await playScript { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in playback.cancel() }
        }
    }

    func makeFork() -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: tools)
    }

    func transcriptEntries() -> [Transcript.Entry] {
        // Empty on purpose. Router's recording types have no public
        // init, so a fixture never assembles transcript values by hand;
        // a test asserts on the wire and on the filesystem instead
        // (plan.md §20.1).
        []
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
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

    /// Invokes the handed tool `name` with the fixed arguments.
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
        _ = try await ToolInvoker.invoke(tool, content: content)
    }
}

/// A resident model whose every session plays the same script.
///
/// All four factories are written out on purpose, like
/// `EchoLLMContainer`: the public default of
/// `makeSession(instructions:tools:)` DROPS `tools`, and a scripted
/// tool call needs them.
struct ScriptedLLMContainer: LoadedLLMContainer {
    /// The script every session plays.
    let script: [ScriptedTurnStep]

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: [])
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: tools)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: [])
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        ScriptedSessionBackend(script: script, tools: tools)
    }
}

/// Makes a loader whose LLM containers play `script`.
///
/// It reuses ``StubModelLoader`` — the injectable seam the stub profile
/// fixtures already have — so a scripted test downloads nothing and
/// loads nothing.
///
/// - Parameter script: The steps every session plays.
/// - Returns: The loader to inject.
func makeScriptedModelLoader(script: [ScriptedTurnStep]) -> StubModelLoader {
    var loader = StubModelLoader()
    loader.makeLLMContainer = { _ in ScriptedLLMContainer(script: script) }
    return loader
}
