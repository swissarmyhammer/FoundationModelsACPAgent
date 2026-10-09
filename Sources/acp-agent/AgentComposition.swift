import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter

/// The CLI choices every subcommand shares (cli-plan.md §5.10, plan.md
/// §20.2): the dotfolder name, and the model switch of the environment.
/// `run` and `acp` both build their agent through ``compose(workingDirectory:environment:reporting:)``,
/// so the two modes cannot drift apart.
///
/// The composition itself is the public `ComposedAgent` of the library, so
/// a host that runs the agent in its own process composes the same agent
/// with no copy of this code. There is no configuration wizardry: the
/// dotfolder name is the one choice a frontend makes, and everything else
/// derives.
enum AgentComposition {
    /// The dotfolder name — the frontend's one choice.
    ///
    /// The name roots the configuration stack — `$XDG_CONFIG_HOME/acp-agent/`
    /// for the user layer, `<cwd>/.acp-agent/` for the project layer — and
    /// the transcript directory, and it is the fallback for the profile's
    /// name (plan.md §2.1). It never goes on the wire: `initialize` reports
    /// the package identity instead (§5).
    static let dotfolderName = "acp-agent"

    /// The environment variable that selects `ComposedAgent.ModelSource.stub` in place
    /// of the live loader. Set it to ``stubModelEnabledValue``.
    ///
    /// It exists because a spawned-binary test has no other deterministic
    /// model: the scripted model of the test support is in-process only,
    /// and the one cross-process control before this was a real small
    /// model whose sampling is not reproducible.
    static let stubModelVariable = "ACP_AGENT_STUB_MODEL"

    /// The value of ``stubModelVariable`` that selects the stub model. Any
    /// other value, and an absent variable, select the live loader.
    static let stubModelEnabledValue = "1"

    /// The environment variable that paces the stub model: the pause, in
    /// milliseconds, between two chunks of the echoed prompt.
    ///
    /// It exists for one reason. ``stubModelVariable`` gives a spawned
    /// binary a deterministic model, but that model answers in one chunk
    /// and in microseconds, so a prompt is over before a signal can reach
    /// it. The interrupt of cli-plan.md §5.9 is a claim about a prompt
    /// that is still running, and this is what holds one open across a
    /// process boundary.
    ///
    /// It is read only on the stub path. An absent value, a value that
    /// is not a number, and a value that is not positive all pace
    /// nothing, and the library's one-chunk echo answers as before.
    static let stubChunkDelayVariable = "ACP_AGENT_STUB_CHUNK_DELAY_MS"

    /// The version the CLI reports. One binary and one version: `--version`
    /// prints this, and `initialize` reports the same value (plan.md §5).
    ///
    /// It stands here because the agent type is named in this file alone
    /// (cli-plan.md §4).
    static let version = RoutedACPAgent.buildVersion

    /// What one composition gives: the public `ComposedAgent` of the library.
    ///
    /// The name stands here so that the `run` and `acp` files do not import
    /// the library: they reach the agent through an ACP connection only
    /// (cli-plan.md §4).
    typealias Composed = ComposedAgent

    /// The process working directory, as a directory URL. It roots the
    /// stack of the `acp` mode, and it is the `run` default (§5.4).
    static var processWorkingDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// Reads ``stubModelVariable`` out of `environment`.
    ///
    /// - Parameter environment: The environment to read.
    /// - Returns: `ComposedAgent.ModelSource.stub` when the variable holds
    ///   ``stubModelEnabledValue``; `ComposedAgent.ModelSource.live`
    ///   otherwise.
    static func modelSource(environment: [String: String]) -> ComposedAgent.ModelSource {
        environment[stubModelVariable] == stubModelEnabledValue ? .stub : .live
    }

    /// Reads ``stubChunkDelayVariable`` out of `environment`.
    ///
    /// - Parameter environment: The environment to read.
    /// - Returns: The pause between two chunks of a stub answer, or
    ///   `nil` when the variable is absent, unreadable, or not positive.
    static func stubChunkDelay(environment: [String: String]) -> Swift.Duration? {
        guard let raw = environment[stubChunkDelayVariable],
            let milliseconds = Int(raw), milliseconds > 0
        else {
            return nil
        }
        return .milliseconds(milliseconds)
    }

    /// Composes the agent of the CLI through the public library helper
    /// `ComposedAgent.compose(name:workingDirectory:environment:modelSource:stubChunkDelay:reporting:)`.
    ///
    /// The CLI adds its own choices only: ``dotfolderName``, and the model
    /// path and the stub pacing that `environment` selects. The library
    /// does the composition, so the CLI holds no copy of it.
    ///
    /// - Parameters:
    ///   - workingDirectory: The directory whose dotfolder stack the
    ///     start-up configuration loads from.
    ///   - environment: The environment the stack reads `XDG_CONFIG_HOME`
    ///     from, and ``modelSource(environment:)`` and
    ///     ``stubChunkDelay(environment:)`` read the model switch from.
    ///   - progress: The progress object the resolution reports into, or
    ///     `nil` for a fresh unobserved one. A caller that draws the
    ///     download bar of cli-plan.md §5.7 makes the object first, hands
    ///     it here, and observes the same object while this call runs.
    /// - Returns: The composed agent, the model path it was built over, and
    ///   the configuration the load resolved.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused,
    ///   and whatever the library composition throws. Each is fatal before
    ///   the wire opens.
    static func compose(
        workingDirectory: URL,
        environment: [String: String],
        reporting progress: ResolutionProgress? = nil
    ) async throws -> ComposedAgent {
        try await ComposedAgent.compose(
            name: DotfolderName(dotfolderName),
            workingDirectory: workingDirectory,
            environment: environment,
            modelSource: modelSource(environment: environment),
            stubChunkDelay: stubChunkDelay(environment: environment),
            reporting: progress)
    }

    /// Makes the loader of `workingDirectory`'s stack under
    /// ``dotfolderName`` — the one construction the `config` reports share
    /// (cli-plan.md §5.10, §5.11).
    ///
    /// - Parameters:
    ///   - workingDirectory: The directory the project layer roots under.
    ///   - environment: The environment the stack reads `XDG_CONFIG_HOME`
    ///     from.
    /// - Returns: The loader. Construction touches no file.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    static func makeConfigurationLoader(
        workingDirectory: URL, environment: [String: String]
    ) throws -> ConfigurationLoader {
        ConfigurationLoader(
            name: try DotfolderName(dotfolderName),
            workingDirectory: workingDirectory,
            environment: environment)
    }
}
