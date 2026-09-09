import Foundation

/// What one `config.yaml` load gave, as a value a doctor component can
/// hold (cli-plan.md §5.12).
///
/// A doctor component reports a failure as a finding and never by
/// throwing, and a component must be `Sendable` while `any Error` is not.
/// So the load runs once, here, and its outcome travels as a value: the
/// merged configuration, or the reason the load did not give one.
public enum ConfigurationLoadOutcome: Sendable {
    /// The load that succeeded, with its warnings and its per-key sources.
    case loaded(LoadedConfiguration)

    /// The reason the load did not succeed, as a person reads it.
    case failed(reason: String)

    /// Loads `config.yaml` through `loader` and keeps what it gave.
    ///
    /// - Parameter loader: The loader of the stack to read.
    public init(of loader: ConfigurationLoader) {
        do {
            self = .loaded(try loader.load())
        } catch {
            self = .failed(reason: String(describing: error))
        }
    }

    /// The merged configuration, or the builtin defaults when the load
    /// failed — because a component that must still report something reads
    /// the same defaults the agent would run with.
    public var configuration: AgentConfiguration {
        switch self {
        case .loaded(let loaded):
            return loaded.configuration
        case .failed:
            return AgentConfiguration()
        }
    }

    /// The warnings the load logged. A load that failed logged none: it
    /// stopped at the schema failure.
    public var warnings: [ConfigurationWarning] {
        switch self {
        case .loaded(let loaded):
            return loaded.warnings
        case .failed:
            return []
        }
    }
}
