import FoundationModelsRouter

/// The readable failure of the agent's profile resolution (plan.md §1).
///
/// Router's `ResolutionFailure` — the error `resolve` throws when no
/// candidate trio fits — is internal, so the resolve path catches
/// `any Error` and carries the underlying message here, next to the name
/// of the profile that did not resolve.
public struct ProfileResolutionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The name of the profile that did not resolve.
    public let profileName: String

    /// The message of the underlying failure.
    public let underlyingMessage: String

    /// A human-readable reason that names the profile and the cause.
    public var description: String {
        "profile \"\(profileName)\" did not resolve: \(underlyingMessage)"
    }
}

extension ProfileConfiguration {
    /// Maps this decoded section to Router's authored profile (plan.md §1).
    ///
    /// The configured ``name`` wins; a section without one falls back to
    /// the dotfolder name, the name's third consumer (plan.md §2.1). Each
    /// slot carries its candidate list in preference order, and the refs
    /// arrive as the `ModelRef` values the config decode produced through
    /// `Codable`, the one decode door that type has.
    ///
    /// `context` stays `nil` on purpose: the config has no context key
    /// (plan.md §2.4), so resolution derives the working context from each
    /// candidate's native maximum instead of the initializer's 8192
    /// default.
    ///
    /// - Parameter fallbackName: The dotfolder name the profile's name
    ///   falls back to when ``name`` is not set.
    /// - Returns: The authored profile to resolve.
    public func definition(fallbackName: DotfolderName) -> ProfileDefinition {
        ProfileDefinition(
            name: name ?? fallbackName.rawValue,
            description: description,
            standard: standard,
            flash: flash,
            embedding: embedding,
            context: nil)
    }

    /// Resolves this section to a resident profile through
    /// `Router.resolve(profile:reporting:)`.
    ///
    /// Every failure — Router's internal `ResolutionFailure` and each
    /// download or load error alike — is caught as `any Error` and
    /// reported as one readable ``ProfileResolutionError``.
    ///
    /// - Parameters:
    ///   - fallbackName: The dotfolder name the profile's name falls back
    ///     to when ``name`` is not set.
    ///   - router: The router that resolves the profile and owns its
    ///     residency.
    ///   - reporting: The UI-bindable progress the resolution drives.
    /// - Returns: The resolved, resident profile. The caller must hold it
    ///   strongly: every `RoutedModel` holds its owning profile weakly.
    /// - Throws: ``ProfileResolutionError`` for every resolution failure.
    public func resolveResident(
        fallbackName: DotfolderName,
        router: Router,
        reporting: ResolutionProgress
    ) async throws(ProfileResolutionError) -> LanguageModelProfile {
        let definition = definition(fallbackName: fallbackName)
        do {
            return try await router.resolve(profile: definition, reporting: reporting)
        } catch {
            throw ProfileResolutionError(
                profileName: definition.name,
                underlyingMessage: String(describing: error))
        }
    }
}
