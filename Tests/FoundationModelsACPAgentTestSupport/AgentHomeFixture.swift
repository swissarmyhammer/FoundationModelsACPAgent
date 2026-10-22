import Foundation
import FoundationModelsACPAgent

/// The one maker of the ``AgentHome`` of a test: a custom home over
/// throwaway folders, so no test reads or writes a folder of the real home
/// directory.
public enum AgentHomeFixture {
    /// Makes a custom home with a new throwaway local root.
    ///
    /// - Parameters:
    ///   - label: The directory label, so a leftover directory says where it
    ///     came from.
    ///   - synced: The synced root, or `nil` (the default) for a new
    ///     throwaway folder. A suite that writes into the user layer gives its
    ///     own folder here.
    /// - Returns: The home.
    public static func make(label: String, synced: URL? = nil) -> AgentHome {
        .makeCustom(
            synced: synced ?? makeResolvedDirectory(label: "\(label)-synced"),
            local: makeResolvedDirectory(label: "\(label)-local"))
    }
}
