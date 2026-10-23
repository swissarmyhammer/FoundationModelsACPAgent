import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter

/// The CLI choices every subcommand shares (cli-plan.md §5.10): the
/// dotfolder name, and the model switch of the environment.
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
    /// of the XDG home for the user layer (``home(environment:)``),
    /// `<cwd>/.acp-agent/` for the project layer — and
    /// the transcript directory, and it is the fallback for the profile's
    /// name. It never goes on the wire: `initialize` reports the package
    /// identity instead, because the dotfolder name is the private choice
    /// of the user.
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

    /// The environment variable that gates the stub model: the path of a
    /// named pipe that the stub reads one byte from before each chunk of
    /// the echoed prompt.
    ///
    /// It exists for one reason. ``stubModelVariable`` gives a spawned
    /// binary a deterministic model, but that model answers in one chunk
    /// and in microseconds, so a prompt is over before a signal can reach
    /// it. The interrupt of cli-plan.md §5.9 is a claim about a prompt
    /// that is still running, and this is what holds one open across a
    /// process boundary. The test lets each chunk go, so a signal always
    /// lands before the chunks end, with no clock.
    ///
    /// It is read only on the stub path. An absent or empty value gates
    /// nothing, and the library's one-chunk echo answers as before.
    static let stubChunkGateVariable = "ACP_AGENT_STUB_CHUNK_GATE"

    /// The environment variable that names the folder of the home of the
    /// CLI (task ^98a44n7). `--home` sets it too (``HomeOptions``). With no
    /// value, the home is the XDG home. See ``home(environment:)``.
    static let homeVariable = "ACP_AGENT_HOME"

    /// The folder of the synced root in the folder of ``homeVariable``.
    static let syncedFolderName = "synced"

    /// The folder of the local root in the folder of ``homeVariable``.
    static let localFolderName = "local"

    /// The version the CLI reports. One binary and one version: `--version`
    /// prints this, and `initialize` reports the same value as the build
    /// version of its `info`.
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

    /// Reads ``stubChunkGateVariable`` out of `environment`.
    ///
    /// - Parameter environment: The environment to read.
    /// - Returns: The path of the named pipe of a stub answer, or `nil`
    ///   when the variable is absent or empty.
    static func stubChunkGate(environment: [String: String]) -> String? {
        guard let path = environment[stubChunkGateVariable], !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Reads the home of the CLI out of `environment` (task ^98a44n7).
    ///
    /// `--home <dir>` reaches this function as ``homeVariable`` too
    /// (``HomeOptions/environment(over:)``), so the option and the variable
    /// resolve the one way:
    ///
    /// - ``homeVariable`` names a folder: the custom home with the synced
    ///   root ``syncedFolderName`` and the local root ``localFolderName`` in
    ///   that folder. A relative path resolves against the process working
    ///   directory.
    /// - With no ``homeVariable``, or an empty one: the XDG home of
    ///   ``dotfolderName``, which keeps the folders that the CLI always used.
    ///
    /// - Parameter environment: The environment to read. The XDG home also
    ///   reads its XDG and cache variables from it.
    /// - Returns: The home.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    static func home(environment: [String: String]) throws -> AgentHome {
        guard let path = environment[homeVariable], !path.isEmpty else {
            return .makeXDG(name: try DotfolderName(dotfolderName), environment: environment)
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        return .makeCustom(
            synced: folder.appendingPathComponent(syncedFolderName, isDirectory: true),
            local: folder.appendingPathComponent(localFolderName, isDirectory: true))
    }

    /// Composes the agent of the CLI through the public library helper
    /// `ComposedAgent.compose(name:workingDirectory:home:environment:modelSource:stubChunkGate:transcriptLocation:secretStore:userDeviceTokens:huggingFaceTokenProvider:reporting:)`.
    /// The CLI gives no `transcriptLocation`: its config files decide.
    ///
    /// The CLI adds its own choices only: ``dotfolderName``, the home that
    /// ``home(environment:)`` reads, and the model path and the stub gate
    /// that `environment` selects. The library does the composition, so the
    /// CLI holds no copy of it.
    ///
    /// The CLI gives no secret store. The default store of the library is
    /// the login Keychain under the service ``dotfolderName``, and that is
    /// the store of the CLI (ACPA-18, D101).
    ///
    /// The CLI gives no Hugging Face token provider. The default provider of
    /// the library, `.environment`, reads `HF_TOKEN`, then
    /// `~/.cache/huggingface/token`, and that is the token of the CLI
    /// (task ^4avf24e).
    ///
    /// With the XDG home, the hooks keep their data and the snapshot
    /// timeline in the XDG data home (ACPA-15, D96), the skills marketplace
    /// store reads its cache folder from `SKILLS_MARKETPLACE_CACHE`, and the
    /// live loader uses the Hugging Face cache that `HF_HUB_CACHE` or
    /// `HF_HOME` names, or `~/.cache/huggingface/hub`.
    ///
    /// - Parameters:
    ///   - workingDirectory: The directory whose dotfolder stack the
    ///     start-up configuration loads from.
    ///   - environment: The environment that ``home(environment:)`` reads
    ///     the home from, and ``modelSource(environment:)`` and
    ///     ``stubChunkGate(environment:)`` read the model switch from.
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
            home: try home(environment: environment),
            environment: environment,
            modelSource: modelSource(environment: environment),
            stubChunkGate: stubChunkGate(environment: environment),
            reporting: progress)
    }

    /// Makes the loader of `workingDirectory`'s stack under
    /// ``dotfolderName`` — the one construction the `config` reports and
    /// `doctor` share (cli-plan.md §5.10, §5.11).
    ///
    /// The stacks of its ``SettingsFolders`` take their user layers from the
    /// home that ``home(environment:)`` reads, the same home as the agent of
    /// ``compose(workingDirectory:environment:reporting:)``. The loader keeps
    /// the settings folders (``ConfigurationLoader/settingsFolders``), so
    /// `doctor` reads the home and the skills and agents stacks of the same
    /// folders.
    ///
    /// - Parameters:
    ///   - workingDirectory: The directory the project layer roots under.
    ///   - environment: The environment that ``home(environment:)`` reads
    ///     the home from.
    ///   - secretStore: The store that gives the value of each secret
    ///     reference `keychain:<name>`, or `nil` (the default) for the login
    ///     Keychain under the service ``dotfolderName``: the store of the CLI
    ///     (ACPA-18, D101). A test gives an in-memory store.
    /// - Returns: The loader. Construction touches no file.
    /// - Throws: `DotfolderNameError` when ``dotfolderName`` is refused.
    static func makeConfigurationLoader(
        workingDirectory: URL, environment: [String: String],
        secretStore: (any SecretStore)? = nil
    ) throws -> ConfigurationLoader {
        ConfigurationLoader(
            settingsFolders: SettingsFolders(
                name: try DotfolderName(dotfolderName), home: try home(environment: environment),
                environment: environment),
            workingDirectory: workingDirectory,
            secretStore: secretStore)
    }
}
