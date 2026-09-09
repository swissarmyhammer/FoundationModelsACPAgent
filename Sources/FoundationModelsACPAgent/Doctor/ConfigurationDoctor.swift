import Foundation
import FoundationModelsExtras

/// The `doctor` component of the configuration (cli-plan.md §5.12, row 1):
/// the configuration loads, every warning the loader returned is listed,
/// and each layer path of §5.10 is reported as it stands on disk.
///
/// The component takes the one load a `doctor` run makes, and the stack
/// that load read. It performs no load of its own and it reads no process
/// environment, so a test drives it over a temporary stack.
///
/// Nothing here throws. A load that failed is one finding with the
/// ``HealthStatus/error`` status, so one broken configuration never stops
/// the other components.
public struct ConfigurationDoctor: Doctorable {
    // MARK: - Constants

    /// The group every finding of this component belongs to.
    public static let category = "configuration"

    /// The check that states whether the configuration loads.
    private static let loadCheckName = "the configuration loads"

    /// What the load check says when the configuration decodes.
    private static let loadPassed = "the merged configuration decodes"

    /// The fix of a load that failed. It names the command that shows the
    /// merged tree and the layer each key came from.
    private static let loadFix = "run acp-agent config show to see the merged tree"

    /// The check that states one section the schema does not know.
    private static let sectionCheckName = "the configuration schema"

    /// The words this component says about the layers of its own stack.
    ///
    /// A layer that is not on disk is no fault, because the stack works
    /// with no file at all. An unreadable one is reported with the `chmod`
    /// command alone, which is the whole repair.
    private static let layerWording = DotfolderLayerCheck.Wording(
        missingReason: "the stack needs no file")

    // MARK: - Stored state

    /// The layer stack the paths are checked against.
    private let stack: DotfolderStack

    /// What the one load of the run gave.
    private let outcome: ConfigurationLoadOutcome

    // MARK: - Doctorable

    /// What this component is called in the doctor report.
    public let doctorName = ConfigurationDoctor.category

    /// The group its findings belong to.
    public let doctorCategory = ConfigurationDoctor.category

    /// Makes the component over one stack and the load that read it.
    ///
    /// - Parameters:
    ///   - stack: The layer stack whose paths are checked.
    ///   - outcome: What the one load of the run gave.
    public init(stack: DotfolderStack, outcome: ConfigurationLoadOutcome) {
        self.stack = stack
        self.outcome = outcome
    }

    /// Reports the load, then one finding per loader warning, then one
    /// finding per layer path, lowest precedence first.
    ///
    /// - Returns: The findings, in that order.
    public func runHealthChecks() async -> [HealthCheck] {
        [Self.check(of: outcome)]
            + outcome.warnings.map(Self.check(of:))
            + stack.layers.map(Self.check(of:))
    }

    // MARK: - The load

    /// The finding of the load itself.
    ///
    /// - Parameter outcome: What the load gave.
    /// - Returns: A pass, or the failure with the reason as its message.
    private static func check(of outcome: ConfigurationLoadOutcome) -> HealthCheck {
        switch outcome {
        case .loaded:
            return .ok(name: loadCheckName, message: loadPassed, category: category)
        case .failed(let reason):
            return .error(
                name: loadCheckName, message: reason, fix: loadFix, category: category)
        }
    }

    // MARK: - The warnings

    /// The finding of one loader warning: the warning's own message, and a
    /// fix that names the key and the file it sits in.
    ///
    /// - Parameter warning: The warning the loader returned.
    /// - Returns: A finding with the ``HealthStatus/warning`` status.
    private static func check(of warning: ConfigurationWarning) -> HealthCheck {
        .warning(
            name: sectionCheckName,
            message: warning.description,
            fix: "remove \"\(key(of: warning))\" from \(ConfigurationLoader.configFileName)",
            category: category)
    }

    /// The dotted key path one warning names: the section, or the tool key
    /// under `tools:`.
    ///
    /// - Parameter warning: The warning the loader returned.
    /// - Returns: The key path a person edits to answer the warning.
    private static func key(of warning: ConfigurationWarning) -> String {
        switch warning {
        case .unknownSection(let name):
            return name
        case .unknownToolSection(let name):
            return AgentConfiguration.CodingKeys.tools.stringValue
                + LoadedConfiguration.keyPathSeparator + name
        }
    }

    // MARK: - The layer paths

    /// The finding of one layer path: whether the directory is on disk, and
    /// whether it can be read and written.
    ///
    /// A layer directory that is not on disk passes. The stack is built to
    /// work with no file at all, so a missing user or project directory is
    /// what a fresh install looks like and not a fault.
    ///
    /// - Parameter layer: The layer to check.
    /// - Returns: The finding of that layer.
    private static func check(of layer: DotfolderStack.Layer) -> HealthCheck {
        DotfolderLayerCheck.check(
            of: layer, wording: layerWording, category: category, requiresWrite: true)
    }
}
