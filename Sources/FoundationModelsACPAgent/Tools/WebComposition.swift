import Foundation
import FoundationModelsMultitool

/// The composition of the Multitool web capability (task ^ba231ka):
/// `tools.web.search` and `tools.web.fetch`.
///
/// **The capability is on by default.** With no key in the configuration
/// and none in the environment, the providers are the keyless pages of
/// Brave and DuckDuckGo. A key in the process environment, or in
/// `tools.web.apiKeys`, adds its keyed provider before them. Multitool's
/// `WebConfiguration.fromEnvironment(_:)` owns the provider table and its
/// order; this type only gives it the merged environment.
///
/// **The web verbs are not in the shell sandbox.** They run in the agent
/// process through `URLSession`. Multitool's address guard refuses private
/// and local addresses.
///
/// **No key value goes out of this type.** The configuration holds each key
/// as `.environment(<name>)`, and its string forms show the provider names
/// only. ``providerNames(section:processEnvironment:)`` gives names, never a
/// key.
public enum WebComposition {
    /// The `WebConfiguration` of one web section: the process environment
    /// with the configured keys put in over it, given to
    /// `WebConfiguration.fromEnvironment(_:)`.
    ///
    /// The call sends no request.
    ///
    /// - Parameters:
    ///   - options: The decoded `tools.web:` body.
    ///   - processEnvironment: The environment of the process.
    /// - Returns: The configuration, whose environment is the merged
    ///   dictionary that each key reads at the time of a call.
    static func configuration(
        options: WebToolOptions, processEnvironment: [String: String]
    ) -> WebConfiguration {
        WebConfiguration.fromEnvironment(options.environment(mergedOver: processEnvironment))
    }

    /// The search providers that one web section puts in force, by name and
    /// in the order to try, or `nil` when the section is off.
    ///
    /// `config show` and `doctor` show this list. A name holds no key and
    /// no URL.
    ///
    /// - Parameters:
    ///   - section: The decoded `tools.web` entry.
    ///   - processEnvironment: The environment of the process.
    /// - Returns: The provider names, or `nil` when the web tool does not
    ///   mount.
    public static func providerNames(
        section: ToolSection<WebToolOptions>, processEnvironment: [String: String]
    ) -> [String]? {
        section.mountedOptions.map { options in
            configuration(options: options, processEnvironment: processEnvironment)
                .providers.map(\.name)
        }
    }

    /// Queues the web capability in `builder`, or does nothing when the
    /// `web:` section is off.
    ///
    /// The capability makes one `URLSession` and sends no request when it
    /// mounts.
    ///
    /// - Parameters:
    ///   - builder: The builder that gets the capability.
    ///   - context: The session whose configuration and environment give
    ///     the providers.
    static func compose(into builder: MultiTool.Builder, context: CatalogContext) {
        guard let options = context.configuration.tools.web.mountedOptions else {
            return
        }
        builder.withWeb(
            configuration: configuration(options: options, processEnvironment: context.environment))
    }
}
