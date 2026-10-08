import Foundation
import FoundationModels
import FoundationModelsRouter

// `RoutedSelectionModel` — the flash slot of a profile as a FoundationModels
// model.
//
// The selection tiers of `searchTools` and of the `skills` tool take
// `any LanguageModel`, and make one `LanguageModelSession` on it for each
// prompt. Router gives no public `LanguageModel` for a slot. This model is
// the join: each generation call of the SDK becomes one Router session of
// the slot. Thus each selection prompt still goes through Router — its
// generation queue, its refusal of a wait on the model of an open
// submission, its recording and its telemetry — and the stub profile of the
// tests answers it the same way it answers every other session.

/// A slot of a resolved profile, presented as a FoundationModels
/// `LanguageModel` that a selection tier prompts.
///
/// Each generation call makes one Router session with the instructions of
/// the call. When the call asks for a `Generable` type, the session gets the
/// response schema of the call as a JSON Schema grammar, so the slot can
/// write only text that decodes as that type. The session gets the last
/// prompt of the call, and the model closes it when the call ends, also
/// when the call fails. Without the close, each Router session keeps a
/// prompt cache entry and can push out the cache of a real session.
///
/// The model serves one prompt for each session, which is the shape of a
/// selection tier. The text of an earlier turn of the same
/// `LanguageModelSession` does not go to the Router session.
struct RoutedSelectionModel: LanguageModel {
    /// The executor that runs each generation call through Router.
    typealias Executor = RoutedSelectionModelExecutor

    /// Makes the Router session of one generation call, from the grammar of
    /// the call (`nil` for a call that asks for plain text) and the
    /// instructions of the call (`nil` for none). An error comes out of the
    /// generation call.
    typealias SessionMaker =
        @Sendable (_ grammar: Grammar?, _ instructions: String?) async throws -> any RoutedSession

    /// The session maker and the token counter that all copies of this
    /// model share. Its identity is the cache key of the executor.
    let source: RoutedSelectionSource

    /// Makes a model over a session maker.
    ///
    /// - Parameters:
    ///   - tokenCounter: Counts the tokens of each answer, for the usage
    ///     that the SDK reports.
    ///   - makeSession: Makes the Router session of each generation call.
    init(tokenCounter: any TokenCounter, makingEach makeSession: @escaping SessionMaker) {
        source = RoutedSelectionSource(makeSession: makeSession, tokenCounter: tokenCounter)
    }

    /// Makes a model over the flash slot of `profile`.
    ///
    /// The session maker captures the profile, not only the slot handle: a
    /// slot handle holds its profile weakly, and the resident models must
    /// outlive the catalog context that made this model.
    ///
    /// - Parameter profile: The resolved profile whose flash slot answers
    ///   each call.
    init(profile: LanguageModelProfile) {
        self.init(tokenCounter: profile.flash.tokenCounter) { grammar, instructions in
            profile.flash.makeSession(
                configuration: SessionConfiguration(instructions: instructions, grammar: grammar))
        }
    }

    /// Guided generation, thus a session can ask for a `Generable` type.
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration])
    }

    /// The cache key of the executor: the identity of the shared source.
    var executorConfiguration: RoutedSelectionModelExecutor.Configuration {
        RoutedSelectionModelExecutor.Configuration(source: ObjectIdentifier(source))
    }
}

/// The session maker and the token counter of one ``RoutedSelectionModel``.
///
/// A class, because its identity is the cache key of the executor: the SDK
/// makes one executor for each distinct configuration. Both stored
/// properties are immutable and `Sendable`, so the class is `Sendable` with
/// no lock.
final class RoutedSelectionSource: Sendable {
    /// Makes the Router session of one generation call.
    let makeSession: RoutedSelectionModel.SessionMaker

    /// Counts the tokens of each answer.
    let tokenCounter: any TokenCounter

    /// Makes a source.
    ///
    /// - Parameters:
    ///   - makeSession: Makes the Router session of one generation call.
    ///   - tokenCounter: Counts the tokens of each answer.
    init(makeSession: @escaping RoutedSelectionModel.SessionMaker, tokenCounter: any TokenCounter) {
        self.makeSession = makeSession
        self.tokenCounter = tokenCounter
    }
}

/// The error of a generation call that ``RoutedSelectionModel`` cannot run.
enum RoutedSelectionModelError: Error, Equatable, CustomStringConvertible {
    /// The transcript of the call holds no prompt, so there is nothing to
    /// send to the Router session.
    case noPrompt

    /// What went wrong, for a log line or a tool result.
    var description: String {
        switch self {
        case .noPrompt:
            "the generation call holds no prompt to send to the flash slot"
        }
    }
}

/// The executor of ``RoutedSelectionModel``: one Router session for each
/// generation call.
struct RoutedSelectionModelExecutor: LanguageModelExecutor {
    /// The cache key that the SDK makes and uses again for the executor.
    struct Configuration: Sendable, Hashable {
        /// The identity of the source of the model.
        let source: ObjectIdentifier
    }

    /// The model that this executor runs for.
    typealias Model = RoutedSelectionModel

    /// Makes an executor. The executor reads nothing from the configuration:
    /// the source comes with the model on each call.
    ///
    /// - Parameter configuration: The cache key.
    /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
    ///   requirement.
    init(configuration: Configuration) throws {}

    /// Runs one generation call: makes the Router session, sends the last
    /// prompt, closes the session, and emits the answer as one text
    /// fragment.
    ///
    /// - Parameters:
    ///   - request: The generation request with the full transcript.
    ///   - model: The model with the source.
    ///   - channel: The channel that the answer goes into.
    /// - Throws: ``RoutedSelectionModelError/noPrompt`` for a transcript with
    ///   no prompt, the error of the schema encode, or whatever the session
    ///   maker or the Router session throws.
    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: RoutedSelectionModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let prompt = try Self.lastPromptText(in: request.transcript)
        let grammar = try request.schema.map(Self.grammar(of:))
        let session = try await model.source.makeSession(
            grammar, Self.instructionsText(in: request.transcript))
        let text: String
        do {
            text = try await session.respond(to: prompt)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        let tokenCount = model.source.tokenCounter.count(text)
        await channel.send(.response(action: .appendText(text, tokenCount: tokenCount)))
    }

    /// The JSON Schema grammar of a response schema: the schema as JSON
    /// text, the same text that Router derives from a `Generable` type.
    ///
    /// - Parameter schema: The response schema of the call.
    /// - Returns: The grammar that constrains the session to the schema.
    /// - Throws: Whatever the JSON encode throws.
    private static func grammar(of schema: GenerationSchema) throws -> Grammar {
        .jsonSchema(String(decoding: try JSONEncoder().encode(schema), as: UTF8.self))
    }

    /// The text of the first instructions entry of `transcript`.
    ///
    /// - Parameter transcript: The transcript of a generation call.
    /// - Returns: The text of the entry, or `nil` when there is none.
    private static func instructionsText(in transcript: Transcript) -> String? {
        transcript.lazy.compactMap { entry -> String? in
            guard case .instructions(let instructions) = entry else { return nil }
            return text(of: instructions.segments)
        }.first
    }

    /// The text of the last prompt entry of `transcript`: the prompt of this
    /// call.
    ///
    /// - Parameter transcript: The transcript of a generation call.
    /// - Returns: The text of the entry.
    /// - Throws: ``RoutedSelectionModelError/noPrompt`` when the transcript
    ///   holds no prompt entry.
    private static func lastPromptText(in transcript: Transcript) throws -> String {
        let prompts = transcript.compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return text(of: prompt.segments)
        }
        guard let prompt = prompts.last else {
            throw RoutedSelectionModelError.noPrompt
        }
        return prompt
    }

    /// The text of the text segments of `segments`, joined.
    ///
    /// - Parameter segments: The segments of a transcript entry.
    /// - Returns: The joined text.
    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined()
    }
}
