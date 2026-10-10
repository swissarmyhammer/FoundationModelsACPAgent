import Foundation
import FoundationModelsExtras

/// The `doctor` component of the runtime (cli-plan.md §5.12, the Skills
/// row): the skills dotfolder stack is found, and each layer of it that is
/// on disk can be read.
///
/// The stack is the one ``ToolCatalog/makeSkillsRegistry(context:)`` builds,
/// under the same dotfolder name, so this component reports the very
/// directories a session reads. A layer that is not on disk passes: skills
/// are optional, and a fresh install has made none. A layer that is on disk
/// and cannot be read is an ``HealthStatus/error``, because the session
/// silently loses every skill in it.
///
/// With `tools.skills: false` no layer is read at all, so the component
/// reports one passing row that says the section is off and reads nothing.
///
/// The agents stack (``ToolCatalog/agentsDotfolderName``) gets the same
/// rows after the skills rows: one per layer when `tools.agents` is on, and
/// one passing row that names `tools.agents.enabled` when it is off.
///
/// The component takes the environment as an argument, so a test drives it
/// over a temporary stack and no test reads the real home directory.
/// Nothing here throws.
///
/// **cli-plan.md §5.12 states a second row, Runtime — "The Metal shader
/// library stands beside the binary" — and that row is superseded.** No
/// `.metallib` stands beside an installed `acp-agent`. mlx-swift ships its
/// shader library as `default.metallib` inside the SwiftPM resource bundle
/// `mlx-swift_Cmlx.bundle`, and SwiftPM puts that bundle beside the built
/// executable. `Bundle.main` of a plain executable roots at the directory
/// that holds the executable, so mlx finds the bundle there without help.
/// The one place a sibling `mlx.metallib` is needed is a `.xctest` binary,
/// which sits two directory levels below its own bundle resources; Router's
/// `MetalLibraryTestBootstrap` makes that symlink for its own test process.
/// A check of a sibling file would therefore fail on every correct install,
/// and a check of the bundle would restate what SwiftPM guarantees and
/// could name no configuration key to fix. See card `^vsj5hyh`.
public struct RuntimeDoctor: Doctorable {
    // MARK: - Constants

    /// The group every finding of this component belongs to.
    public static let category = "runtime"

    /// The check that states the skills section is off.
    private static let skillsToolCheckName = "the skills tool"

    /// The dotted key path of the skills section a row names.
    private static let skillsKey =
        AgentConfiguration.CodingKeys.tools.stringValue
        + LoadedConfiguration.keyPathSeparator
        + ToolsConfiguration.CodingKeys.skills.stringValue

    /// The words this component says about the layers of its own stack.
    ///
    /// A layer that is not on disk is no fault, because skills are
    /// optional. An unreadable one loses every skill in it, and a person
    /// either opens the directory or takes it away.
    private static let layerWording = DotfolderLayerCheck.Wording(
        missingReason: "skills are optional",
        noun: ToolCatalog.skillsDotfolderName,
        unreadableCost: ", so its skills are lost",
        unreadableFixHint: ", or remove it")

    /// The check that states the agents section is off.
    private static let agentsToolCheckName = "the agents tool"

    /// The dotted key path that turns the agents tool off, as the git and
    /// environment rows of ``ToolsDoctor`` name their `enabled` keys.
    private static let agentsEnabledKey =
        AgentConfiguration.CodingKeys.tools.stringValue
        + LoadedConfiguration.keyPathSeparator
        + ToolsConfiguration.CodingKeys.agents.stringValue
        + LoadedConfiguration.keyPathSeparator
        + AgentsToolOptions.CodingKeys.enabled.stringValue

    /// The words this component says about the layers of the agents stack.
    ///
    /// A layer that is not on disk is no fault, because agents are
    /// optional. An unreadable one loses every agent in it.
    private static let agentsLayerWording = DotfolderLayerCheck.Wording(
        missingReason: "agents are optional",
        noun: ToolCatalog.agentsDotfolderName,
        unreadableCost: ", so its agents are lost",
        unreadableFixHint: ", or remove it")

    // MARK: - Stored state

    /// The resolved configuration, whose `tools.skills:` section says
    /// whether any layer is read.
    private let configuration: AgentConfiguration

    /// The directory `--cwd` names, which roots the project layer of the
    /// skills stack.
    private let workingDirectory: URL

    /// The environment the stack reads, above all `XDG_CONFIG_HOME`, which
    /// roots the user layer.
    private let environment: [String: String]

    // MARK: - Doctorable

    /// What this component is called in the doctor report.
    public let doctorName = RuntimeDoctor.category

    /// The group its findings belong to.
    public let doctorCategory = RuntimeDoctor.category

    /// Makes the component over one resolved configuration and the tree the
    /// skills stack roots in.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration.
    ///   - workingDirectory: The directory `--cwd` names.
    ///   - environment: The environment the stack reads.
    public init(
        configuration: AgentConfiguration, workingDirectory: URL, environment: [String: String]
    ) {
        self.configuration = configuration
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Reports one finding per layer of the skills stack, lowest precedence
    /// first, or the one row of a skills section that is off, then the same
    /// for the agents stack.
    ///
    /// - Returns: The findings, in that order.
    public func runHealthChecks() async -> [HealthCheck] {
        skillsChecks() + agentsChecks()
    }

    /// The findings of the skills section: one per layer of the skills
    /// stack, or the one row of a section that is off.
    ///
    /// - Returns: The findings, lowest precedence first.
    private func skillsChecks() -> [HealthCheck] {
        guard case .enabled = configuration.tools.skills else {
            return [
                DisabledSectionCheck.check(
                    name: Self.skillsToolCheckName, key: Self.skillsKey, category: Self.category)
            ]
        }
        return skillsStack.layers.map(Self.check(ofSkillsLayer:))
    }

    /// The findings of the agents section: one per layer of the agents
    /// stack, or the one row of a section that is off by either shape, the
    /// scalar `agents: false` or `enabled: false`.
    ///
    /// - Returns: The findings, lowest precedence first.
    private func agentsChecks() -> [HealthCheck] {
        guard configuration.tools.agents.mountedOptions != nil else {
            return [
                DisabledSectionCheck.check(
                    name: Self.agentsToolCheckName, key: Self.agentsEnabledKey, category: Self.category)
            ]
        }
        return agentsStack.layers.map { layer in
            DotfolderLayerCheck.check(
                of: layer, wording: Self.agentsLayerWording, category: Self.category, requiresWrite: false)
        }
    }

    /// The dotfolder stack the agent registry reads, under the dotfolder
    /// name ``ToolCatalog/agentsDotfolderName``, so this component reports
    /// the very layers a session reads.
    private var agentsStack: DotfolderStack {
        DotfolderStack(
            name: ToolCatalog.agentsDotfolderName, workingDirectory: workingDirectory,
            environment: environment)
    }

    // MARK: - The skills stack

    /// The dotfolder stack the skills registry is built over.
    ///
    /// It carries the dotfolder name ``ToolCatalog/skillsDotfolderName``,
    /// so this component reports the very layers a session reads.
    private var skillsStack: DotfolderStack {
        DotfolderStack(
            name: ToolCatalog.skillsDotfolderName, workingDirectory: workingDirectory,
            environment: environment)
    }

    /// The finding of one skills layer: whether it is on disk, and whether
    /// it can be read.
    ///
    /// - Parameter layer: The layer to check.
    /// - Returns: The finding of that layer.
    private static func check(ofSkillsLayer layer: DotfolderStack.Layer) -> HealthCheck {
        DotfolderLayerCheck.check(
            of: layer, wording: layerWording, category: category, requiresWrite: false)
    }
}
