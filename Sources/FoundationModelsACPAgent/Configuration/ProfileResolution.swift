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
  /// Resolves the selected profile (``definition``) to a resident profile
  /// through `Router.resolve(profile:reporting:)`.
  ///
  /// Every failure — Router's internal `ResolutionFailure` and each
  /// download or load error alike — is caught as `any Error` and
  /// reported as one readable ``ProfileResolutionError``.
  ///
  /// - Parameters:
  ///   - router: The router that resolves the profile and owns its
  ///     residency.
  ///   - reporting: The UI-bindable progress the resolution drives.
  /// - Returns: The resolved, resident profile. The caller must hold it
  ///   strongly: every `RoutedModel` holds its owning profile weakly.
  /// - Throws: ``ProfileResolutionError`` for every resolution failure.
  public func resolveResident(
    router: Router,
    reporting: ResolutionProgress
  ) async throws(ProfileResolutionError) -> LanguageModelProfile {
    let definition = definition
    do {
      return try await router.resolve(profile: definition, reporting: reporting)
    } catch {
      throw ProfileResolutionError(
        profileName: definition.name,
        underlyingMessage: String(describing: error))
    }
  }
}
