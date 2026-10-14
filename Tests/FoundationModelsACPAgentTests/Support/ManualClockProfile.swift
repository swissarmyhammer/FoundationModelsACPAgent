import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras

@testable import FoundationModelsACPAgent
// `Router.useRunClock(_:)` is internal: only a test gives a router its
// clock. A debug build compiles Router with testing enabled.
@testable import FoundationModelsRouter

/// Resolves a profile over the stub models whose sessions wait on `runClock`
/// for the timeout of each run and for the settle period of each background
/// call.
///
/// With a `ManualRunClock`, no such timer ends before the test advances the
/// clock, so the result of a test does not depend on the load of the machine.
/// The profile is the profile of ``makeStubProfile(cacheDirectory:recordingsDirectory:loader:)``.
///
/// - Parameters:
///   - cacheDirectory: Where the router caches.
///   - loader: The loader the router loads through.
///   - runClock: The clock of the runs of each session of the profile.
/// - Returns: The resolved profile.
/// - Throws: Whatever resolving the profile throws.
func makeStubProfile(
    cacheDirectory: URL, loader: StubModelLoader, runClock: any RunClock
) async throws -> LanguageModelProfile {
    let router = EchoModel.makeRouter(cacheDirectory: cacheDirectory, loader: loader)
    await router.useRunClock(runClock)
    return try await router.resolve(
        profile: ProfileDefinition(
            name: "stub",
            description: "the stub profile these fixtures run on",
            standard: ["stub/standard"],
            flash: ["stub/flash"],
            embedding: ["stub/embedding"]
        ),
        reporting: ResolutionProgress()
    )
}
