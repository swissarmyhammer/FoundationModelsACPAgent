import FoundationModelsExtras

/// The layer a reported configuration key came from (cli-plan.md §5.11).
///
/// `DotfolderStack.Source` names the dotfolder layers and has no case for
/// the builtin layer, because the builtin layer is a resource of the
/// library and not a dotfolder (§5.10). A key no dotfolder layer set has no
/// entry in `LoadedConfiguration.sources`; this type maps that absent entry
/// to ``builtin``, so a report can name every key.
public enum ConfigurationLayerName: String, Encodable, Equatable, Sendable {
    /// Layer 1: the builtin file `builtin.config.yaml`, with the
    /// property defaults of `AgentConfiguration` as the decode fallback.
    case builtin

    /// A cached remote skill marketplace layer. A host adds this layer
    /// itself, below the local layers, and it is never trusted. This
    /// package derives no such layer, so the name appears only when a
    /// host builds a stack that holds one.
    case marketplace

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
        case .marketplace?:
            self = .marketplace
        case .defaults?:
            self = .defaults
        case .user?:
            self = .user
        case .project?:
            self = .project
        }
    }
}
