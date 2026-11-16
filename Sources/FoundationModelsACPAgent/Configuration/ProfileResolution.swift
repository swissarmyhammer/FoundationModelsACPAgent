import FoundationModelsRouter

/// The readable failure of the agent's profile resolution.
///
/// Router's `ResolutionFailure` — the error `resolve` throws when no
/// candidate set fits — is internal, so the resolve path catches
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
  /// Maps this decoded section to Router's authored profile: the profile
  /// that ``preset`` names (ACPA-21, D189).
  ///
  /// The four candidate lists, the description and the context of the
  /// decision slot come from the preset. The configured ``name`` is a label
  /// only: it wins over the name of the preset; a section without one falls
  /// back to the dotfolder name. The name has three consumers: the
  /// configuration stack, the transcript root and this default.
  ///
  /// `context` stays `nil` on purpose: the context size comes from the
  /// model, so resolution derives the working context from each
  /// candidate's native maximum.
  ///
  /// - Parameter fallbackName: The dotfolder name the profile's name
  ///   falls back to when ``name`` is not set.
  /// - Returns: The authored profile to resolve.
  public func definition(fallbackName: DotfolderName) -> ProfileDefinition {
    var definition = presetProfile
    definition.name = name ?? fallbackName.rawValue
    definition.context = nil
    return definition
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
