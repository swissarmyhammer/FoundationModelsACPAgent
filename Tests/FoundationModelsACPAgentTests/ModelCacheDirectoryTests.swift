import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The model cache folder of the home (ACPA-16, ^98a44n7): the live download,
/// the resolver and `doctor` use the folder of a custom home, also when
/// `HF_HOME` and `HF_HUB_CACHE` name a different folder. With the XDG home,
/// nothing changes.
///
/// The router loader keeps its Hugging Face cache private, and
/// `ProfileDoctor` keeps its resolver private. Thus the suite reads each
/// folder with `Mirror`. No test asks the network, and no test loads a model.
struct ModelCacheDirectoryTests {
    // MARK: - Constants

    /// The environment variable that names the Hugging Face home, whose
    /// `hub` subdirectory is the cache.
    private static let homeVariable = "HF_HOME"

    /// The environment variable that names the hub cache directly.
    private static let hubCacheVariable = "HF_HUB_CACHE"

    /// The subdirectory of `HF_HOME` that holds the cache.
    private static let hubDirectoryName = "hub"

    /// The path of stored properties from a `LiveModelLoader` to the folder
    /// of its Hugging Face cache: the Extras `MLXModelLoader`, its
    /// `HubCache`, and the folder of that cache.
    private static let liveLoaderCachePath = ["modelLoader", "cache", "cacheDirectory"]

    /// The path of stored properties from a `SystemModelResolver` to its
    /// hub cache folder.
    private static let resolverCachePath = ["cacheDirectory"]

    /// The path of stored properties from a `ProfileDoctor` to the hub cache
    /// folder of its resolver.
    private static let profileDoctorCachePath = ["resolver", "cacheDirectory"]

    /// A memory figure far above the profile floor, so the profile
    /// component does not read the machine this suite runs on.
    private static let generousMemoryBytes: Int64 = 68_719_476_736

    /// A free-disk figure far above any download, for the same reason.
    private static let generousDiskBytes: Int64 = 1_099_511_627_776

    // MARK: - Helpers

    /// Makes a new empty folder for one test.
    ///
    /// - Parameter name: The name of the folder in the test.
    /// - Returns: The created folder.
    private static func makeFolder(named name: String) -> URL {
        makeResolvedDirectory(label: "ModelCacheDirectoryTests-\(name)")
    }

    /// An environment where `HF_HOME` and `HF_HUB_CACHE` each name a folder
    /// that is not the folder of the host.
    ///
    /// - Returns: The environment of the two variables.
    private static func environmentWithOtherCaches() -> [String: String] {
        [
            homeVariable: makeFolder(named: "environment-home").path,
            hubCacheVariable: makeFolder(named: "environment-hub-cache").path,
        ]
    }

    /// The hub cache folder of `HF_HOME` in an environment that names no
    /// `HF_HUB_CACHE`.
    ///
    /// - Parameter home: The folder that `HF_HOME` names.
    /// - Returns: The `hub` subdirectory of `home`.
    private static func hubCache(underHome home: URL) -> URL {
        home.appendingPathComponent(hubDirectoryName, isDirectory: true)
    }

    /// The folder at the end of `path` in `value`, read with `Mirror`.
    ///
    /// - Parameters:
    ///   - value: The value to read.
    ///   - path: The names of the stored properties, from `value` to the
    ///     folder.
    /// - Returns: The path of the folder, or `nil` when the path does not
    ///   lead to a URL.
    private static func folder(in value: Any, at path: [String]) -> String? {
        let leaf = path.reduce(value as Any?) { node, name in
            node.flatMap { Mirror(reflecting: $0).descendant(name) }
        }
        return (leaf as? URL)?.standardizedFileURL.path
    }

    /// The `ProfileDoctor` of the `doctor` registry over a fresh fixture.
    ///
    /// - Parameter environment: The environment variables to add to the
    ///   environment of the fixture. `ACP_AGENT_HOME` here gives a custom
    ///   home; with none, the home is the XDG home.
    /// - Returns: The profile component, or `nil` when the registry has none.
    private static func profileDoctor(environment: [String: String]) -> ProfileDoctor? {
        let fixture = ConfigCommandFixture(label: "ModelCacheDirectoryTests-doctor")
        let components = AcpAgentCommand.Doctor.components(
            workingDirectory: fixture.workspace,
            environment: fixture.environment.merging(environment) { _, new in new },
            prober: StubToolsProber(),
            memoryBytes: generousMemoryBytes, freeDiskBytes: generousDiskBytes)
        return components.lazy.compactMap { $0 as? ProfileDoctor }.first
    }

    // MARK: - The live download

    /// The live loader of a given folder downloads into that folder, and
    /// reads the weights from it.
    @Test func theLiveLoaderOfAGivenFolderUsesThatFolder() {
        let hostCache = Self.makeFolder(named: "live-host")

        let loader = ComposedAgent.makeLiveModelLoader(
            modelCacheDirectory: hostCache, tokenProvider: .environment)

        #expect(Self.folder(in: loader, at: Self.liveLoaderCachePath) == hostCache.standardizedFileURL.path)
    }

    /// The live loader of the XDG home of the process environment uses the
    /// same cache as the loader that the router makes with no argument.
    @Test func theLiveLoaderOfTheXDGHomeKeepsTheDefaultCache() throws {
        let home = AgentHome.makeXDG(
            name: try DotfolderName(AgentComposition.dotfolderName),
            environment: ProcessInfo.processInfo.environment)

        let loader = ComposedAgent.makeLiveModelLoader(
            modelCacheDirectory: home.modelCacheDirectory, tokenProvider: .environment)

        let defaultFolder = Self.folder(in: LiveModelLoader(), at: Self.liveLoaderCachePath)
        #expect(defaultFolder != nil)
        #expect(Self.folder(in: loader, at: Self.liveLoaderCachePath) == defaultFolder)
    }

    // MARK: - The resolver

    /// A given folder is the hub cache of the resolver, also when `HF_HOME`
    /// and `HF_HUB_CACHE` name a different folder.
    @Test func aGivenFolderWinsOverTheEnvironmentInTheResolver() {
        let hostCache = Self.makeFolder(named: "resolver-host")

        let resolver = SystemModelResolver(
            environment: Self.environmentWithOtherCaches(), modelCacheDirectory: hostCache)

        #expect(Self.folder(in: resolver, at: Self.resolverCachePath) == hostCache.standardizedFileURL.path)
    }

    /// With no folder, the resolver reads its hub cache from `HF_HOME`, as
    /// before.
    @Test func theResolverOfNoFolderReadsTheEnvironment() {
        let home = Self.makeFolder(named: "resolver-home")

        let resolver = SystemModelResolver(environment: [Self.homeVariable: home.path])

        #expect(
            Self.folder(in: resolver, at: Self.resolverCachePath)
                == Self.hubCache(underHome: home).standardizedFileURL.path)
    }

    // MARK: - The doctor

    /// The profile check of `doctor` reads the model cache of a custom home,
    /// also when `HF_HOME` and `HF_HUB_CACHE` name a different folder.
    @Test func theCacheOfACustomHomeWinsOverTheEnvironmentInTheDoctor() throws {
        let homeFolder = Self.makeFolder(named: "doctor-host")
        let environment = Self.environmentWithOtherCaches()
            .merging([AgentComposition.homeVariable: homeFolder.path]) { _, new in new }
        let hostCache = try AgentComposition.home(environment: environment).modelCacheDirectory

        let doctor = try #require(Self.profileDoctor(environment: environment))

        #expect(Self.folder(in: doctor, at: Self.profileDoctorCachePath) == hostCache.standardizedFileURL.path)
    }

    /// With the XDG home, the profile check of `doctor` reads its hub cache
    /// from `HF_HOME`, as before.
    @Test func theDoctorOfTheXDGHomeReadsTheEnvironment() throws {
        let home = Self.makeFolder(named: "doctor-home")

        let doctor = try #require(Self.profileDoctor(environment: [Self.homeVariable: home.path]))

        #expect(
            Self.folder(in: doctor, at: Self.profileDoctorCachePath)
                == Self.hubCache(underHome: home).standardizedFileURL.path)
    }
}
