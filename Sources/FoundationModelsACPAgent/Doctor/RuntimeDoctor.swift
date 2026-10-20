import Foundation
import FoundationModelsExtras

/// The `doctor` component of the runtime (cli-plan.md §5.12, the Skills
/// row): the skills dotfolder stack is found, and each layer of it that is
/// on disk can be read.
///
/// The stack is the one ``ToolCatalog/makeSkillsSource(context:)`` builds,
/// under the same dotfolder name, so this component reports the very
/// directories a session reads. A layer that is not on disk passes: skills
/// are optional, and a fresh install has made none. A layer that is on disk
/// and cannot be read is an ``HealthStatus/error``, because the session
/// silently loses every skill in it.
///
/// The agents stack (``ToolCatalog/agentsDotfolderName``) gets the same
/// rows after the skills rows: one per layer. The skills tool and the
/// `agents` tool are always on, thus the component reads no configuration.
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

    /// The skills section: a layer row says that skills are optional.
    ///
    /// A layer that is not on disk is no fault, because skills are optional.
    /// An unreadable one loses every skill in it, and a person either opens
    /// the directory or takes it away.
    private static let skillsSection = DotfolderSection(
        dotfolderName: ToolCatalog.skillsDotfolderName,
        wording: DotfolderLayerCheck.Wording(
            missingReason: "skills are optional",
            noun: ToolCatalog.skillsDotfolderName,
            unreadableCost: ", so its skills are lost",
            unreadableFixHint: ", or remove it"))

    /// The agents section: a layer row says that agents are optional.
    ///
    /// A layer that is not on disk is no fault, because agents are optional.
    /// An unreadable one loses every agent in it.
    private static let agentsSection = DotfolderSection(
        dotfolderName: ToolCatalog.agentsDotfolderName,
        wording: DotfolderLayerCheck.Wording(
            missingReason: "agents are optional",
            noun: ToolCatalog.agentsDotfolderName,
            unreadableCost: ", so its agents are lost",
            unreadableFixHint: ", or remove it"))

    /// The values that make the rows of one dotfolder section different from
    /// the rows of an other section.
    private struct DotfolderSection {
        /// The dotfolder name of the stack that the section reads.
        let dotfolderName: String

        /// The words of a layer row.
        let wording: DotfolderLayerCheck.Wording
    }

    // MARK: - Stored state

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

    /// Makes the component over the tree the skills stack roots in.
    ///
    /// - Parameters:
    ///   - workingDirectory: The directory `--cwd` names.
    ///   - environment: The environment the stack reads.
    public init(workingDirectory: URL, environment: [String: String]) {
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Reports one finding per layer of the skills stack, lowest precedence
    /// first, then the same for the agents stack.
    ///
    /// - Returns: The findings, in that order.
    public func runHealthChecks() async -> [HealthCheck] {
        checks(of: Self.skillsSection) + checks(of: Self.agentsSection)
    }

    /// The findings of one dotfolder section: one per layer of its stack.
    ///
    /// - Parameter section: The values of the section.
    /// - Returns: The findings, lowest precedence first.
    private func checks(of section: DotfolderSection) -> [HealthCheck] {
        dotfolderStack(named: section.dotfolderName).layers.map { layer in
            DotfolderLayerCheck.check(
                of: layer, wording: section.wording, category: Self.category, requiresWrite: false)
        }
    }

    /// The dotfolder stack that a registry of the session builds over the
    /// dotfolder name `name`, so this component reports the very layers a
    /// session reads.
    ///
    /// - Parameter name: The dotfolder name, for example
    ///   ``ToolCatalog/skillsDotfolderName``.
    /// - Returns: The stack, rooted in the working directory and the
    ///   environment of this component.
    private func dotfolderStack(named name: String) -> DotfolderStack {
        DotfolderStack(name: name, workingDirectory: workingDirectory, environment: environment)
    }
}
