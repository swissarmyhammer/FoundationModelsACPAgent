import Foundation
import FoundationModelsACPAgent

/// Composes the agent over the stub model through the public
/// `ComposedAgent.compose`, with its home in throwaway folders. The suites
/// that test the public composition share this one setup, so the setup
/// cannot drift apart between them.
///
/// - Parameters:
///   - name: The bare dotfolder name of the host.
///   - label: The directory label, so a leftover directory says where it
///     came from.
///   - workspace: The working directory of the composition, or `nil` (the
///     default) for a new throwaway directory. A caller that must use the
///     same directory after the composition gives it here.
///   - home: The home to give to the composition, or `nil` (the default) for
///     a new custom home in throwaway folders (``AgentHomeFixture``). A
///     caller that writes into the home, or tests the XDG preset, gives it
///     here.
///   - secretStore: The store to give to the composition, or `nil` (the
///     default) for the default store of the library.
///   - userDeviceTokens: The bearer tokens of the devices of the user to give
///     to the composition (ACPA-5b). None by default.
///   - environment: The environment of the composition, below the key of the
///     defaults layer. Empty by default.
/// - Returns: The composition.
/// - Throws: `DotfolderNameError` when `name` is refused, the write error of
///   the defaults layer, or whatever the composition throws.
public func composeStubAgent(
    name: String,
    label: String,
    workspace: URL? = nil,
    home: AgentHome? = nil,
    secretStore: (any SecretStore)? = nil,
    userDeviceTokens: Set<String> = [],
    environment: [String: String] = [:]
) async throws -> ComposedAgent {
    let workspace = workspace ?? makeResolvedDirectory(label: "\(label)-repo")
    return try await ComposedAgent.compose(
        name: DotfolderName(name),
        workingDirectory: workspace,
        home: home ?? AgentHomeFixture.make(label: label),
        environment: try StubAgentDefaultsLayer.makeEnvironment(name: name, base: environment),
        modelSource: .stub,
        secretStore: secretStore,
        userDeviceTokens: userDeviceTokens)
}
