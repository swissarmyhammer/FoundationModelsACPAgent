import Foundation
import FoundationModelsACPAgent

/// The environment variable that roots the user configuration layer. The
/// stub composition sets it, so no composition touches the real home
/// directory.
private let configHomeVariable = "XDG_CONFIG_HOME"

/// Composes the agent over the stub model through the public
/// `ComposedAgent.compose`, with each configuration root in a throwaway
/// directory. The suites that test the public composition share this one
/// setup, so the setup cannot drift apart between them.
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
/// - Returns: The composition.
/// - Throws: `DotfolderNameError` when `name` is refused, the write error of
///   the defaults layer, or whatever the composition throws.
public func composeStubAgent(
    name: String,
    label: String,
    workspace: URL? = nil,
    secretStore: (any SecretStore)? = nil
) async throws -> ComposedAgent {
    let configHome = makeResolvedDirectory(label: "\(label)-config")
    let workspace = workspace ?? makeResolvedDirectory(label: "\(label)-repo")
    let environment = try StubAgentDefaultsLayer.makeEnvironment(
        name: name, base: [configHomeVariable: configHome.path])
    return try await ComposedAgent.compose(
        name: DotfolderName(name),
        workingDirectory: workspace,
        environment: environment,
        modelSource: .stub,
        secretStore: secretStore)
}
