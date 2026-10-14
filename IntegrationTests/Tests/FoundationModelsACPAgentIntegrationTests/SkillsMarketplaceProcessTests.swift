import Foundation
import FoundationModelsACPAgentTestSupport
import Marketplace
import Testing

// MARK: - Tier 3: the skills marketplaces of a spawned agent
//
// The shipped `tools.skills.marketplaces` list names the `main` branch of the
// `swissarmyhammer/skills` repository on GitHub, and a session start fetches
// each marketplace into the folder that `SKILLS_MARKETPLACE_CACHE` names.
//
// The suites of this package must be offline and repeatable. Thus each child
// that `PipedChildProcess` spawns reads the offline defaults layer of
// `TierThreeFixture`, which sets an empty marketplace list. This suite proves
// that rule, and proves the shipped list one time on purpose.
//
// It carries no gate. The package boundary is the selection: the root
// `swift test` never sees this target, and
// `swift test --package-path IntegrationTests` runs it.

/// The marketplace fetch of a spawned `acp-agent run`.
struct SkillsMarketplaceProcessTests {
    // MARK: - Constants

    /// The subcommand of `acp-agent` that runs one prompt.
    private static let runSubcommand = "run"

    /// The prompt text. The stub model echoes it.
    private static let promptText = "a session starts and reads its skills"

    /// The exit code of an `acp-agent run` prompt that reached its end.
    private static let endTurnExitCode: Int32 = 0

    // MARK: - The subprocess driver

    /// Runs one stub-model prompt through the built `acp-agent run`, with
    /// `cache` as the marketplace cache folder, through the shared driver
    /// ``BuiltExecutableRun/runAgent(arguments:label:configHome:environment:)``.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory says where it
    ///     came from.
    ///   - cache: The folder that `SKILLS_MARKETPLACE_CACHE` names.
    ///   - environment: The extra environment pairs, on top of the stub model
    ///     and the cache folder.
    /// - Returns: The finished run.
    /// - Throws: The locator or spawn error.
    private static func runPrompt(
        label: String, cache: URL, environment: [String: String] = [:]
    ) async throws -> BuiltExecutableRun {
        try await BuiltExecutableRun.runAgent(
            arguments: [runSubcommand, promptText],
            label: label,
            environment: TierThreeFixture.stubModelEnvironment
                .merging([MarketplaceStore.cacheDirectoryVariable: cache.path]) { _, cache in cache }
                .merging(environment) { _, extra in extra })
    }

    /// The names of the entries in `folder`.
    ///
    /// - Parameter folder: The folder to read.
    /// - Returns: The entry names.
    /// - Throws: The read error.
    private static func entries(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    // MARK: - The contract

    /// A spawned agent with the configuration of the suites fetches no
    /// marketplace: the prompt ends, and the cache folder stays empty.
    @Test
    func aSpawnedAgentFetchesNoSkillsMarketplace() async throws {
        let cache = makeResolvedDirectory(label: "SkillsMarketplaceOffline-cache")

        let run = try await Self.runPrompt(label: "SkillsMarketplaceOffline", cache: cache)

        #expect(run.exitCode == Self.endTurnExitCode, "stderr: \(run.standardError)")
        #expect(try Self.entries(of: cache).isEmpty, "the cache folder holds a fetch")
    }

    /// The shipped marketplace list reaches GitHub. This test uses the
    /// network on purpose: it is the one test of this package that proves
    /// the default marketplace path.
    ///
    /// ``TierThreeFixture/noDefaultsLayerValue`` removes the offline
    /// defaults layer, so the child reads the shipped list. The
    /// prompt ends, and the session start fetched a snapshot of the
    /// `swissarmyhammer/skills` repository into the cache folder.
    @Test
    func theShippedMarketplaceListFetchesTheGitHubSkillsRepositoryOverTheNetwork() async throws {
        let cache = makeResolvedDirectory(label: "SkillsMarketplaceShipped-cache")

        let run = try await Self.runPrompt(
            label: "SkillsMarketplaceShipped", cache: cache,
            environment: [
                TierThreeFixture.defaultsDirectoryVariable: TierThreeFixture.noDefaultsLayerValue
            ])

        #expect(run.exitCode == Self.endTurnExitCode, "stderr: \(run.standardError)")
        #expect(try !Self.entries(of: cache).isEmpty, "stderr: \(run.standardError)")
    }
}
