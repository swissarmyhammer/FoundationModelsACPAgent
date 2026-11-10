import Foundation
import FoundationModelsACPAgent
import FoundationModelsExtras

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
///   - mode: The tool mode to give to the composition. `.open` by default,
///     the mode of the `acp-agent` CLI.
///   - sandboxProbe: The probe that tells the composition if the process is
///     sandboxed. The default reads the test process, which is not
///     sandboxed. A suite that tests the check of the mode gives
///     `.fixed(_:)`.
///   - openTestudoDownloadURL: The download URL of OpenTestudo to give to
///     the composition, or `nil` (the default) for none.
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
  environment: [String: String] = [:],
  mode: ToolMode = .open,
  sandboxProbe: SandboxProbe = .live,
  openTestudoDownloadURL: URL? = nil
) async throws -> ComposedAgent {
  let workspace = workspace ?? makeResolvedDirectory(label: "\(label)-repo")
  return try await ComposedAgent.compose(
    name: DotfolderName(name),
    workingDirectory: workspace,
    home: home ?? AgentHomeFixture.make(label: label),
    mode: mode,
    sandboxProbe: sandboxProbe,
    openTestudoDownloadURL: openTestudoDownloadURL,
    environment: try StubAgentDefaultsLayer.makeEnvironment(name: name, base: environment),
    modelSource: .stub,
    secretStore: secretStore,
    userDeviceTokens: userDeviceTokens)
}
