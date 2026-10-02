import Foundation
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import FoundationModelsRouterTestSupport

/// The composition of a live agent for the live-model suites: the real
/// models load through `LiveModelLoader`, and the decoding is greedy.
///
/// The caller closes the harness at the end of its run, and keeps no
/// reference to it after that. The agent then goes, and the model pool of the
/// process evicts its models (``ProcessModelPool``).
enum LiveAgent {
    /// Writes `userConfigYAML` into a fresh user layer, composes the agent
    /// over a live router, and wires a recording harness to it.
    ///
    /// The agent resolves its profile here, thus the real models load here.
    /// Greedy decoding makes a run repeatable: the same model and the same
    /// code give the same tool calls in every run.
    ///
    /// - Parameters:
    ///   - label: The directory label of the calling suite, so a leftover
    ///     directory says where it came from.
    ///   - userConfigYAML: The user-layer `config.yaml` of the agent.
    /// - Returns: The wired harness. No `initialize` went over it yet.
    /// - Throws: Whatever the write, the configuration load or the agent
    ///   throws.
    static func makeHarness(label: String, userConfigYAML: String) async throws -> AgentClientHarness {
        // Under `swift test`, mlx-swift does not find its shader library
        // beside the test binary. Router's bootstrap symlinks it once per
        // process, and it must run before the first model load.
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        let userDirectory = makeResolvedDirectory(label: "\(label)-user")
        try userConfigYAML.write(
            to: userDirectory.appendingPathComponent(ConfigurationLoader.configFileName),
            atomically: true, encoding: .utf8)
        let configuration = try ConfigurationLoader(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            workingDirectory: userDirectory,
            userDirectory: userDirectory,
            environment: [:]
        ).load().configuration
        let router = Router(
            recordingsDir: makeResolvedDirectory(label: "\(label)-recordings"),
            loader: LiveModelLoader(),
            samplingMode: .greedy)
        let agent = try await RoutedACPAgent(
            name: DotfolderName(AgentClientHarness.dotfolderName),
            router: router,
            configuration: configuration,
            userDirectory: userDirectory,
            environment: [:])
        return await AgentClientHarness.makeRecording(agent: agent)
    }
}
