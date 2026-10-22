import CryptoKit
import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsCodeContext
import Marketplace
import Testing

@testable import FoundationModelsACPAgent

/// `AgentHome` (task ^98a44n7): the one home of a host, with a synced root
/// and a local root. The CLI uses the XDG preset, which keeps the paths of
/// today; an app gives its own two roots.
///
/// Each test uses temporary folders only, and gives the XDG variables in its
/// environment, so no test reads the real home directory.
struct AgentHomeTests {
    // MARK: - Constants

    /// The dotfolder name of the host in these tests.
    private static let dotfolderName = "home-test"

    /// The environment variable of the XDG configuration home.
    private static let configHomeVariable = "XDG_CONFIG_HOME"

    /// The environment variable of the XDG data home.
    private static let dataHomeVariable = "XDG_DATA_HOME"

    /// The environment variable of the Hugging Face hub cache.
    private static let hubCacheVariable = "HF_HUB_CACHE"

    // MARK: - Fixture

    /// A custom home: a temporary synced root and a temporary local root.
    ///
    /// - Parameter label: The prefix that names the test.
    /// - Returns: The home.
    private static func makeCustomHome(label: String) -> AgentHome {
        .makeCustom(
            synced: makeResolvedDirectory(label: "AgentHomeTests-\(label)-synced"),
            local: makeResolvedDirectory(label: "AgentHomeTests-\(label)-local"))
    }

    /// The lowercase hexadecimal SHA-256 of the path of `directory`.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The digest text.
    private static func digest(of directory: URL) -> String {
        SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - The custom preset

    /// A custom home puts the projects folder in the synced root.
    @Test
    func theProjectsFolderOfACustomHomeIsInTheSyncedRoot() {
        let home = Self.makeCustomHome(label: "projects")

        #expect(home.projectsDirectory == home.synced.appendingPathComponent("projects", isDirectory: true))
    }

    /// A custom home puts the hooks, the skills marketplace cache and the
    /// model cache in the local root.
    @Test
    func theMachineFoldersOfACustomHomeAreInTheLocalRoot() {
        let home = Self.makeCustomHome(label: "machine")

        #expect(home.hooksDirectory == home.local.appendingPathComponent("hooks", isDirectory: true))
        #expect(
            home.skillsMarketplaceCacheDirectory
                == home.local.appendingPathComponent("skills-marketplace", isDirectory: true))
        #expect(home.modelCacheDirectory == home.local.appendingPathComponent("models", isDirectory: true))
    }

    /// A custom home puts the metadata cache of the router and the install
    /// record of the language servers in the local root.
    @Test
    func thePackageCachesOfACustomHomeAreInTheLocalRoot() {
        let home = Self.makeCustomHome(label: "package-caches")

        #expect(home.routerCacheDirectory == home.local.appendingPathComponent("router", isDirectory: true))
        #expect(
            home.languageServerInstallRecordDirectory
                == home.local.appendingPathComponent("language-servers", isDirectory: true))
    }

    /// The machine state of one project is in
    /// `<local>/projects/<sha256 of the standardized path>/`, thus two
    /// spellings of one folder give one state folder.
    @Test
    func theProjectStateFolderIsKeyedByTheDigestOfTheStandardizedPath() {
        let home = Self.makeCustomHome(label: "state")
        let project = makeResolvedDirectory(label: "AgentHomeTests-state-repo")
        let otherSpelling = URL(
            fileURLWithPath: project.path + "/sub/..", isDirectory: true)

        let state = home.projectStateDirectory(of: project)

        #expect(
            state
                == home.local.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(Self.digest(of: project), isDirectory: true))
        #expect(home.projectStateDirectory(of: otherSpelling) == state)
    }

    // MARK: - The XDG preset

    /// The XDG preset of the CLI keeps the paths of today: the synced root is
    /// `$XDG_CONFIG_HOME/<name>/`, the local root is `$XDG_DATA_HOME/<name>/`,
    /// and the hooks are in `$XDG_DATA_HOME/<name>/hooks`.
    @Test
    func theXDGPresetRootsAreTheXDGFoldersOfTheName() throws {
        let configHome = makeResolvedDirectory(label: "AgentHomeTests-xdg-config")
        let dataHome = makeResolvedDirectory(label: "AgentHomeTests-xdg-data")
        let environment = [Self.configHomeVariable: configHome.path, Self.dataHomeVariable: dataHome.path]

        let home = AgentHome.makeXDG(name: try DotfolderName(Self.dotfolderName), environment: environment)

        #expect(home.synced == configHome.appendingPathComponent(Self.dotfolderName, isDirectory: true))
        #expect(home.local == dataHome.appendingPathComponent(Self.dotfolderName, isDirectory: true))
        #expect(home.hooksDirectory == home.local.appendingPathComponent("hooks", isDirectory: true))
    }

    /// The XDG preset keeps the caches of today: the skills marketplace cache
    /// that `SKILLS_MARKETPLACE_CACHE` names, and the Hugging Face hub cache
    /// that `HF_HUB_CACHE` names.
    @Test
    func theXDGPresetCachesAreTheCachesOfTheEnvironment() throws {
        let marketplaceCache = makeResolvedDirectory(label: "AgentHomeTests-xdg-marketplace")
        let hubCache = makeResolvedDirectory(label: "AgentHomeTests-xdg-hub")
        let environment = [
            MarketplaceStore.cacheDirectoryVariable: marketplaceCache.path, Self.hubCacheVariable: hubCache.path,
        ]

        let home = AgentHome.makeXDG(name: try DotfolderName(Self.dotfolderName), environment: environment)

        #expect(home.skillsMarketplaceCacheDirectory.standardizedFileURL == marketplaceCache.standardizedFileURL)
        #expect(home.modelCacheDirectory.standardizedFileURL == hubCache.standardizedFileURL)
    }

    /// The XDG preset gives no folder of its own to the router and to the
    /// code context: each package keeps the folder of today, the router its
    /// metadata cache and the code context its language server install
    /// record.
    @Test
    func theXDGPresetKeepsThePackageCaches() throws {
        let home = AgentHome.makeXDG(name: try DotfolderName(Self.dotfolderName), environment: [:])

        #expect(home.routerCacheDirectory == nil)
        #expect(home.languageServerInstallRecordDirectory == LspAutoInstall.defaultFailureRecordDirectory)
    }
}
