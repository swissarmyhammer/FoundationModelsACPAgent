import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRanker
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The selection tier of `searchTools`, which
/// ``ToolCatalog/makeSearchSelection(profile:)`` makes.
///
/// The test puts the configuration in a real `SelectionTier` and runs one
/// search, so the test reads the behavior that `searchTools` gets: the tier
/// prompts the flash slot of the profile, and the search answers with the
/// selection of that slot.
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

    /// The tier that the selection factory configures prompts the flash slot
    /// of the profile, and the search answers with the selection of that
    /// slot.
    @Test func theTierSelectsThroughTheFlashSlotOfTheProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchSelectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try await makeStubProfile(
            cacheDirectory: directory,
            loader: makeScriptedModelLoader(script: [.textDelta(Self.selectionJSON), .endPass]))
        let catalog = OneCandidateCatalog()
        let config = try ToolCatalog.makeSearchSelection(profile: profile)(catalog.ids)
        let tier = SelectionTier(catalog: catalog, config: config, onDiagnostic: { _ in })

        let matches = try await tier.search(intent: Self.intent, limit: 1)

        #expect(matches.map(\.id) == [Self.candidateID])
    }
}
