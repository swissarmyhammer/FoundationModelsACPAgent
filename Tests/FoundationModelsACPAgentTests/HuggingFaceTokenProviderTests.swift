import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import HuggingFace
import Testing

@testable import FoundationModelsACPAgent

/// The Hugging Face token of the host, and the metadata cache of the live
/// router (task ^4avf24e): the host gives one `TokenProvider` to the
/// composition, the live router sends its token on each download and on each
/// sizing request, and the metadata cache of the router is in the local root
/// of a custom home.
///
/// The router keeps its loader and its metadata source private, and the
/// loader keeps its Extras loader private. Thus the suite reads each token
/// provider with `Mirror`. The sizing GET goes to a `StubURLProtocol` host of
/// its own, so no test asks the network, and no test loads a model.
struct HuggingFaceTokenProviderTests {
    // MARK: - Constants

    /// The token of the provider that the host gives.
    private static let hostToken = "host-token"

    /// The number of GETs of one metadata fetch: `config.json` and the tree
    /// listing.
    private static let requestsPerFetch = 2

    /// The HTTP status of each stub answer.
    private static let okStatus = 200

    /// The path of stored properties from a live router to the token provider
    /// of its downloads: the `LiveModelLoader`, its Extras `MLXModelLoader`,
    /// and the provider of that loader.
    private static let downloadTokenPath = ["loader", "modelLoader", "tokenProvider"]

    /// The path of stored properties from a live router to the token provider
    /// of its sizing requests: the metadata reader, its
    /// `HuggingFaceMetadataSource`, and the provider of that source.
    private static let sizingTokenPath = ["metadataReader", "source", "tokenProvider"]

    /// The environment keys that name the home directory and the XDG roots.
    private static let homeKeys = ["HOME", AgentHome.configHomeEnvironmentKey, AgentHome.dataHomeEnvironmentKey]

    // MARK: - Helpers

    /// The live router of `home`, over `provider`, as the composition makes
    /// it.
    ///
    /// - Parameters:
    ///   - home: The home of the host.
    ///   - provider: The token provider that the host gives.
    ///   - label: The label of the throwaway folders of the test.
    /// - Returns: The router.
    /// - Throws: The error of the router construction.
    private static func makeLiveRouter(
        home: AgentHome, provider: TokenProvider, label: String
    ) throws -> Router {
        try ComposedAgent.makeRouter(
            for: .live,
            gatedBy: nil,
            recordingInto: makeResolvedDirectory(label: "\(label)-recordings"),
            hooks: AgentHooks(dataDirectory: home.hooksDirectory).dispatcher,
            home: home,
            huggingFaceTokenProvider: provider)
    }

    /// The token provider at the end of `path` in `value`, read with
    /// `Mirror`.
    ///
    /// - Parameters:
    ///   - value: The value to read.
    ///   - path: The names of the stored properties, from `value` to the
    ///     provider.
    /// - Returns: The provider.
    /// - Throws: When the path does not lead to a `TokenProvider`.
    private static func tokenProvider(in value: Any, at path: [String]) throws -> TokenProvider {
        let leaf = path.reduce(value as Any?) { node, name in
            node.flatMap { Mirror(reflecting: $0).descendant(name) }
        }
        return try #require(leaf as? TokenProvider)
    }

    /// The `Authorization` header of each sizing GET that a metadata source
    /// over `provider` sends to a stub host of its own.
    ///
    /// - Parameter provider: The token provider of the source.
    /// - Returns: The header of each request, in order.
    /// - Throws: The error of the fetch.
    private static func sizingHeaders(sentWith provider: TokenProvider) async throws -> [String?] {
        let recorder = RequestRecorder()
        let host = "\(UUID().uuidString.lowercased()).hub.example.test"
        StubURLProtocol.install(forHost: host) { request in
            recorder.record(request)
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: Self.okStatus, httpVersion: nil, headerFields: nil))
            return (response, Data("[]".utf8))
        }
        let source = HuggingFaceMetadataSource(
            endpoint: try #require(URL(string: "https://\(host)")),
            session: StubURLProtocol.makeSession(),
            tokenProvider: provider)
        _ = try await source.fetchRawMetadata(repo: "org/model", revision: nil)
        return recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
    }

    // MARK: - The metadata cache

    /// The metadata cache of the live router of a custom home is in the local
    /// root of that home.
    @Test func theMetadataCacheOfACustomHomeIsUnderItsLocalRoot() throws {
        let home = AgentHomeFixture.make(label: "HuggingFaceTokenProviderTests-cache")

        let router = try Self.makeLiveRouter(home: home, provider: .none, label: "cache")

        // Plain paths, and not standardized ones: standardizing drops the
        // `/private` of a folder that exists, and keeps it on a folder that
        // the router did not make yet.
        #expect(router.cacheDirectory.path.hasPrefix(home.local.path + "/"))
    }

    // MARK: - The token of the host

    /// The token provider of the host reaches the downloads of the live
    /// router.
    @Test func theHostTokenReachesTheDownloads() async throws {
        let home = AgentHomeFixture.make(label: "HuggingFaceTokenProviderTests-download")

        let router = try Self.makeLiveRouter(
            home: home, provider: .fixed(token: Self.hostToken), label: "download")

        let provider = try Self.tokenProvider(in: router, at: Self.downloadTokenPath)
        #expect(try await provider.getToken() == Self.hostToken)
    }

    /// The token provider of the host reaches the sizing of the live router,
    /// and each sizing GET carries its token as a bearer header.
    @Test func theHostTokenReachesTheSizingAsABearerHeader() async throws {
        let home = AgentHomeFixture.make(label: "HuggingFaceTokenProviderTests-sizing")

        let router = try Self.makeLiveRouter(
            home: home, provider: .fixed(token: Self.hostToken), label: "sizing")

        let provider = try Self.tokenProvider(in: router, at: Self.sizingTokenPath)
        let headers = try await Self.sizingHeaders(sentWith: provider)
        #expect(headers == Array(repeating: "Bearer \(Self.hostToken)", count: Self.requestsPerFetch))
    }

    /// With the home directory and the XDG roots of the environment pointed
    /// at an empty folder, the live router of the XDG home sends the token of
    /// the host, and reads no token file from that folder: the folder stays
    /// empty.
    @Test func theXDGHomeOverAnEmptyFolderSendsTheHostToken() async throws {
        let empty = makeResolvedDirectory(label: "HuggingFaceTokenProviderTests-empty")
        let environment = Dictionary(uniqueKeysWithValues: Self.homeKeys.map { ($0, empty.path) })
        let home = AgentHome.makeXDG(name: try DotfolderName("hf-token-tests"), environment: environment)

        let router = try Self.makeLiveRouter(
            home: home, provider: .fixed(token: Self.hostToken), label: "xdg")

        let downloads = try Self.tokenProvider(in: router, at: Self.downloadTokenPath)
        let sizing = try Self.tokenProvider(in: router, at: Self.sizingTokenPath)
        #expect(try await downloads.getToken() == Self.hostToken)
        #expect(try await sizing.getToken() == Self.hostToken)
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
    }
}
