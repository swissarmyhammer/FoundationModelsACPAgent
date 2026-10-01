import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRanker
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The selection tier of `searchTools`, which
/// ``ToolCatalog/makeSearchSelection(makingEach:)`` makes.
///
/// `SelectionConfig(model:)` takes an async throwing session factory. Each
/// test puts the configuration in a real `SelectionTier` and runs one
/// search, so the test reads the behavior that `searchTools` gets: the tier
/// awaits the session maker, and an error of the maker comes out of the
/// search.
@Suite struct SearchSelectionTests {
    /// The id of the one candidate of the catalog.
    private static let candidateID = FilesVerbSupport.readVerbPath

    /// The intent that each search sends.
    private static let intent = "read one text file from the workspace"

    /// The answer of the scripted flash slot, in the shape that
    /// `SelectionTier` decodes.
    private static let selectionJSON = #"{"ids":["\#(candidateID)"]}"#

    /// A catalog with one candidate, ``candidateID``.
    private struct OneCandidateCatalog: SelectionCatalog {
        /// The one id of the catalog.
        let ids = [SearchSelectionTests.candidateID]

        /// The text of the one candidate. The summary and the full block are
        /// the same text.
        private static let candidateText = "Reads one file of the workspace."

        /// Gives the summary of the one candidate, and `nil` for each other
        /// id.
        ///
        /// - Parameter id: The id to give the summary of.
        /// - Returns: The summary, or `nil` when `id` is not in the catalog.
        func summaryBlock(forID id: String) -> String? {
            block(forID: id)
        }

        /// Gives the full block of the one candidate, and `nil` for each
        /// other id.
        ///
        /// - Parameter id: The id to give the block of.
        /// - Returns: The block, or `nil` when `id` is not in the catalog.
        func block(forID id: String) -> String? {
            id == SearchSelectionTests.candidateID ? Self.candidateText : nil
        }
    }

    /// Records each grammar that the session maker gets. It is an actor, so
    /// the maker must await each record.
    private actor MakerLog {
        /// Each grammar that the maker got, in call order.
        private(set) var grammars: [Grammar] = []

        /// Records one grammar.
        ///
        /// - Parameter grammar: The grammar that the maker got.
        func record(_ grammar: Grammar) {
            grammars.append(grammar)
        }
    }

    /// The error that the throwing session maker throws.
    private struct SessionMakerFailure: Error {}

    /// Makes a selection tier over ``OneCandidateCatalog``, with the
    /// configuration that `makeSearchSelection(makingEach:)` gives for the
    /// ids of the catalog.
    ///
    /// - Parameter maker: The session maker under test.
    /// - Returns: The tier.
    /// - Throws: Whatever the selection factory throws.
    private static func makeTier(
        makingEach maker: @escaping ToolCatalog.GuidedSessionMaker
    ) throws -> SelectionTier {
        let catalog = OneCandidateCatalog()
        let config = try ToolCatalog.makeSearchSelection(makingEach: maker)(catalog.ids)
        return SelectionTier(catalog: catalog, config: config, onDiagnostic: { _ in })
    }

    /// The tier awaits a session maker that suspends. The search answers
    /// with the selection of the session that the maker made, and the maker
    /// got the id grammar of the catalog.
    @Test func theTierAwaitsAnAsyncSessionMaker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchSelectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try await makeStubProfile(
            cacheDirectory: directory,
            loader: makeScriptedModelLoader(script: [.textDelta(Self.selectionJSON), .endPass]))
        let log = MakerLog()
        let tier = try Self.makeTier(makingEach: { grammar, instructions in
            await log.record(grammar)
            return profile.flash.makeGuidedSession(grammar: grammar, instructions: instructions)
        })

        let matches = try await tier.search(intent: Self.intent, limit: 1)

        #expect(matches.map(\.id) == [Self.candidateID])
        let grammars = await log.grammars
        #expect(grammars.count == 1)
        let grammar = try #require(grammars.first)
        let schema = try #require(Self.schemaText(of: grammar))
        let idSchema = try SelectionTier.idEnumSchema(ids: [Self.candidateID])
        #expect(try Self.jsonObject(schema) == Self.jsonObject(idSchema))
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

    /// Decodes a JSON text. `idEnumSchema(ids:)` writes the keys in no fixed
    /// order, so the test compares the decoded objects, not the texts.
    ///
    /// - Parameter text: The JSON text to decode.
    /// - Returns: The decoded object.
    /// - Throws: Whatever `JSONSerialization` throws, and an expectation
    ///   failure when the text is not a JSON object.
    private static func jsonObject(_ text: String) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    /// An error of the session maker comes out of the search that asked for
    /// the session. The tier does not hide it as an empty selection.
    @Test func aThrowingSessionMakerSurfacesItsErrorFromTheSearch() async throws {
        let tier = try Self.makeTier(makingEach: { _, _ in throw SessionMakerFailure() })

        await #expect(throws: SessionMakerFailure.self) {
            try await tier.search(intent: Self.intent, limit: 1)
        }
    }
}
