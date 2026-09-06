import FoundationModelsExtras

/// The layer a reported configuration key came from (cli-plan.md §5.11).
///
/// `DotfolderStack.Source` names the layers on disk and has no case for
/// the builtin defaults, because the builtin layer is code, not a file
/// (§5.10). A key no layer set has no entry in
/// `LoadedConfiguration.sources`; this type maps that absent entry to
/// ``builtin``, so a report can name every key.
public enum ConfigurationLayerName: String, Encodable, Equatable, Sendable {
    /// The property defaults of `AgentConfiguration`: in code, no file.
    case builtin

    /// The consumer-shipped defaults directory. This package passes none,
    /// so the name appears only under a `<NAME>_DEFAULTS_DIR` override.
    case defaults

    /// The user layer, `$XDG_CONFIG_HOME/<name>/`.
    case user

    /// The project layer, `<cwd>/.<name>/`.
    case project

    /// Names the layer of `source`, or ``builtin`` when no layer set the
    /// key.
    ///
    /// - Parameter source: The layer the loader recorded, or `nil` for a
    ///   key no layer set.
    public init(_ source: DotfolderStack.Source?) {
        switch source {
        case nil:
            self = .builtin
        case .defaults?:
            self = .defaults
        case .user?:
            self = .user
        case .project?:
            self = .project
        }
    }
}
