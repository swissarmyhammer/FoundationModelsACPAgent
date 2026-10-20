import Foundation
import FoundationModelsACPAgent

/// The environment variable that roots the user configuration layer. The
/// stub composition sets it, so no composition touches the real home
/// directory.
private let configHomeVariable = "XDG_CONFIG_HOME"

/// The environment variable that roots the default hook data directory. The
/// stub composition sets it, so the snapshots of a composition do not go
/// into the real home directory.
private let dataHomeVariable = "XDG_DATA_HOME"

/// Composes the agent over the stub model through the public
/// `ComposedAgent.compose`, with each configuration root and the data home
/// in a throwaway directory. The suites that test the public composition
/// share this one setup, so the setup cannot drift apart between them.
///
/// - Parameters:
///   - name: The bare dotfolder name of the host.
///   - label: The directory label, so a leftover directory says where it
///     came from.
///   - workspace: The working directory of the composition, or `nil` (the
///     default) for a new throwaway directory. A caller that must use the
///     same directory after the composition gives it here.
///   - secretStore: The store to give to the composition, or `nil` (the
///     default) for the default store of the library.
///   - hooksDataDirectory: The hook data directory to give to the
///     composition, or `nil` (the default) to let the composition use the
///     data home.
///   - dataHome: The `XDG_DATA_HOME` of the composition, or `nil` (the
///     default) for a new throwaway directory. A caller that must find the
///     default hook data directory gives it here.
///   - rootSettingsFolder: The root settings folder to give to the
///     composition, or `nil` (the default) for the XDG layers.
///   - configHome: The `XDG_CONFIG_HOME` of the composition, or `nil` (the
///     default) for a new throwaway directory. A caller that writes a file
///     into the XDG user layer gives it here.
/// - Returns: The composition.
/// - Throws: `DotfolderNameError` when `name` is refused, the write error of
///   the defaults layer, or whatever the composition throws.
public func composeStubAgent(
    name: String,
    label: String,
    workspace: URL? = nil,
    secretStore: (any SecretStore)? = nil,
    hooksDataDirectory: URL? = nil,
    dataHome: URL? = nil,
    rootSettingsFolder: URL? = nil,
    configHome: URL? = nil
) async throws -> ComposedAgent {
    let configHome = configHome ?? makeResolvedDirectory(label: "\(label)-config")
    let dataHome = dataHome ?? makeResolvedDirectory(label: "\(label)-data")
    let workspace = workspace ?? makeResolvedDirectory(label: "\(label)-repo")
    let environment = try StubAgentDefaultsLayer.makeEnvironment(
        name: name, base: [configHomeVariable: configHome.path, dataHomeVariable: dataHome.path])
    return try await ComposedAgent.compose(
        name: DotfolderName(name),
        workingDirectory: workspace,
        rootSettingsFolder: rootSettingsFolder,
        environment: environment,
        modelSource: .stub,
        secretStore: secretStore,
        hooksDataDirectory: hooksDataDirectory)
}
