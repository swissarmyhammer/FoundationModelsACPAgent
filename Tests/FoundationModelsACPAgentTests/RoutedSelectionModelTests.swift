import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsRanker
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

// MARK: - The flash slot as a FoundationModels model
//
// The selection tiers of `searchTools` and of the `skills` tool take a
// FoundationModels `LanguageModel`. `RoutedSelectionModel` is that model
// over the flash slot of the profile. Each case drives a real
// `LanguageModelSession` on the model, the same way a selection tier does,
// over the stub profile and its scripted flash slot. No case loads a real
// model.

/// The executor of ``RoutedSelectionModel``: the session it makes for each
/// call, the grammar and the instructions of that session, the text it
/// gives back, and the close of the session.
@Suite struct RoutedSelectionModelTests {
    // MARK: - Constants

    /// The id that the scripted flash slot selects.
    private static let candidateID = FilesVerbSupport.readVerbPath

    /// The answer of the scripted flash slot, in the shape of `Selection`.
    private static let selectionJSON = #"{"ids":["\#(candidateID)"]}"#

    /// The instructions that each session on the model gets.
    private static let instructions = "the assembled prefix of the selection tier"

    /// The prompt that each call sends.
    private static let prompt = "read one text file from the workspace"

    /// The number of closes that one Router session gets.
    private static let oneClose = 1

    /// The number of Router sessions that one call makes.
    private static let oneSession = 1

    // MARK: - Doubles

    /// The error that the throwing session maker throws.
    private struct SessionMakerFailure: Error {}

    /// Records what the session maker got, and each session it made. It is
    /// an actor, so the maker must await each record.
    private actor MakerLog {
        /// Each grammar that the maker got, in call order.
        private(set) var grammars: [Grammar?] = []

        /// Each instructions text that the maker got, in call order.
        private(set) var instructions: [String?] = []

        /// Each session that the maker made, in call order.
        private(set) var sessions: [CloseCountingRoutedSession] = []

        /// Records one call of the maker.
        ///
        /// - Parameters:
        ///   - grammar: The grammar that the maker got.
        ///   - text: The instructions that the maker got.
        ///   - session: The session that the maker made.
        func record(grammar: Grammar?, instructions text: String?, session: CloseCountingRoutedSession) {
            grammars.append(grammar)
            instructions.append(text)
            sessions.append(session)
        }
    }

    // MARK: - Helpers

    /// Resolves a stub profile whose flash slot plays `script`.
    ///
    /// - Parameters:
    ///   - script: The steps of each pass of the scripted model.
    ///   - recorder: Records each prompt that the scripted model gets.
    /// - Returns: The resolved profile.
    /// - Throws: Whatever the profile resolve throws.
    private static func makeProfile(
        script: [ScriptedPassStep], recorder: PromptRecorder? = nil
    ) async throws -> LanguageModelProfile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutedSelectionModelTests-\(UUID().uuidString)", isDirectory: true)
        return try await makeStubProfile(
            cacheDirectory: directory,
            loader: makeScriptedModelLoader(script: script, recorder: recorder))
    }

    /// Makes a model whose sessions are close counters over sessions of the
    /// flash slot of `profile`, and records each call in `log`.
    ///
    /// - Parameters:
    ///   - profile: The profile whose flash slot makes each session.
    ///   - log: The log of the maker.
    /// - Returns: The model under test.
    private static func makeCountingModel(
        profile: LanguageModelProfile, log: MakerLog
    ) -> RoutedSelectionModel {
        RoutedSelectionModel(tokenCounter: profile.flash.tokenCounter) { grammar, instructions in
            let session = CloseCountingRoutedSession(
                wrapping: profile.flash.makeSession(
                    configuration: SessionConfiguration(instructions: instructions, grammar: grammar)))
            await log.record(grammar: grammar, instructions: instructions, session: session)
            return session
        }
    }

    /// Asks `model` for one `Selection`, as a selection tier does.
    ///
    /// - Parameter model: The model under test.
    /// - Returns: The selection of the answer.
    /// - Throws: Whatever the session throws.
    private static func select(on model: RoutedSelectionModel) async throws -> Selection {
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt, generating: Selection.self).content
    }

    /// Gives the JSON Schema text of a `.jsonSchema` grammar.
    ///
    /// - Parameter grammar: The grammar to read.
    /// - Returns: The schema text, or `nil` for a grammar of a different kind.
    private static func schemaText(of grammar: Grammar) -> String? {
        if case .jsonSchema(let text) = grammar {
            return text
        }
        return nil
    }

    /// Decodes a JSON text into an object, so two texts compare by value and
    /// not by key order.
    ///
    /// - Parameter text: The JSON text.
    /// - Returns: The decoded object.
    /// - Throws: Whatever `JSONSerialization` throws, and an expectation
    ///   failure when the text is not a JSON object.
    private static func jsonObject(_ text: String) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    // MARK: - Tests

    /// A guided call on the model answers with the text of the flash slot,
    /// decoded as the type the session asked for, and the flash slot got the
    /// prompt of the call.
    @Test func aGuidedCallAnswersWithTheTextOfTheFlashSlot() async throws {
        let recorder = PromptRecorder()
        let profile = try await Self.makeProfile(
            script: [.textDelta(Self.selectionJSON), .endPass], recorder: recorder)

        let selection = try await Self.select(on: RoutedSelectionModel(profile: profile))

        #expect(selection == Selection(ids: [Self.candidateID]))
        #expect(await recorder.prompts.contains { $0.contains(Self.prompt) })
    }

    /// The Router session of a call gets the instructions of the
    /// FoundationModels session, and the response schema of the call as a
    /// JSON Schema grammar.
    @Test func theSessionOfACallGetsTheInstructionsAndTheSchemaGrammar() async throws {
        let profile = try await Self.makeProfile(script: [.textDelta(Self.selectionJSON), .endPass])
        let log = MakerLog()

        _ = try await Self.select(on: Self.makeCountingModel(profile: profile, log: log))

        #expect(await log.instructions == [Self.instructions])
        let grammars = await log.grammars
        #expect(grammars.count == Self.oneSession)
        let grammar = try #require(grammars.first ?? nil, "the session got no grammar")
        let schema = try #require(Self.schemaText(of: grammar), "the grammar is not a JSON Schema")
        let expected = String(decoding: try JSONEncoder().encode(Selection.generationSchema), as: UTF8.self)
        #expect(try Self.jsonObject(schema) == Self.jsonObject(expected))
    }

    /// The model closes the Router session of a call one time, when the call
    /// ends. Without the close, each session keeps a prompt cache entry.
    @Test func eachCallClosesItsRouterSessionOneTime() async throws {
        let profile = try await Self.makeProfile(script: [.textDelta(Self.selectionJSON), .endPass])
        let log = MakerLog()

        _ = try await Self.select(on: Self.makeCountingModel(profile: profile, log: log))

        let session = try #require(await log.sessions.first)
        #expect(await session.closeCount == Self.oneClose)
    }

    /// A call whose Router session fails still closes that session, and the
    /// error comes out of the call.
    @Test func aFailedCallStillClosesItsRouterSession() async throws {
        let profile = try await Self.makeProfile(script: [.fail(.guardrailViolation)])
        let log = MakerLog()
        let model = Self.makeCountingModel(profile: profile, log: log)

        await #expect(throws: (any Error).self) {
            try await Self.select(on: model)
        }

        let session = try #require(await log.sessions.first)
        #expect(await session.closeCount == Self.oneClose)
    }

    /// An error of the session maker comes out of the call. The model does
    /// not hide it as an empty answer.
    @Test func anErrorOfTheSessionMakerComesOutOfTheCall() async throws {
        let profile = try await Self.makeProfile(script: [.endPass])
        let model = RoutedSelectionModel(tokenCounter: profile.flash.tokenCounter) { _, _ in
            throw SessionMakerFailure()
        }

        await #expect(throws: SessionMakerFailure.self) {
            try await Self.select(on: model)
        }
    }
}
