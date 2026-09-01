import Foundation
import FoundationModels
import FoundationModelsRouter

// MARK: - Recorded-session fixtures for the transcript read side

// `TranscriptStore` tests need real recorded session directories, because
// no shipped `TranscriptRecorder` is reachable and `TranscriptEvent` has no
// public init. The router records events by diffing
// `backend.transcriptEntries()` after each turn, so the stub backend here
// accumulates one `.prompt` and one `.response` entry per turn — unlike
// `EchoSessionBackend`, whose empty transcript records nothing.

/// A session backend whose synthetic transcript grows by one `.prompt`
/// and one `.response` entry per turn, so a routed session over it
/// records real events.
///
/// `@unchecked Sendable`, because the transcript array mutates; the owning
/// `RoutedSession` actor serializes every call, so no concurrent access
/// occurs in these fixtures.
final class TranscriptStubBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// The synthetic transcript so far, in append order.
    private var entries: [Transcript.Entry]

    /// Makes a backend seeded with `entries` — empty for a fresh session,
    /// and a copy of the parent's transcript for a fork.
    ///
    /// - Parameter entries: The seed transcript.
    init(entries: [Transcript.Entry] = []) {
        self.entries = entries
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        entries.append(
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
        entries.append(
            .response(
                Transcript.Response(segments: [.text(Transcript.TextSegment(content: prompt))])))
        return prompt
    }

    func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(prompt)
            continuation.finish()
        }
    }

    func makeFork() -> any LanguageModelSessionBackend {
        TranscriptStubBackend(entries: entries)
    }

    func transcriptEntries() -> [Transcript.Entry] {
        entries
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
        (1, 1)
    }
}

/// A resident model that hands every session a fresh
/// ``TranscriptStubBackend``.
///
/// All four factories are written out, for the reason the fixture file
/// comment of `StubProfileFixtures.swift` states: the public default of
/// `makeSession(instructions:tools:)` drops `tools`.
struct TranscriptStubContainer: LoadedLLMContainer {
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        TranscriptStubBackend()
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        TranscriptStubBackend()
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        TranscriptStubBackend(entries: Array(transcript))
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        TranscriptStubBackend(entries: Array(transcript))
    }
}

/// Resolves a profile whose sessions record real transcript events.
///
/// Each call stands up its own router, so two calls give two recorder
/// runs — each with its own `seq` numbering that restarts at zero.
///
/// - Parameters:
///   - cacheDirectory: Where the router caches. A fresh temporary
///     directory per call keeps runs apart.
///   - recordingsDirectory: The durable transcripts root the router
///     records under when a session names no per-session root.
/// - Returns: The resolved profile. It retains its router, so the caller
///   holds the profile alone.
/// - Throws: Whatever resolving the profile throws.
func makeRecordingStubProfile(
    cacheDirectory: URL, recordingsDirectory: URL
) async throws -> LanguageModelProfile {
    try await makeStubProfile(
        cacheDirectory: cacheDirectory,
        recordingsDirectory: recordingsDirectory,
        loader: StubModelLoader(makeLLMContainer: { TranscriptStubContainer() }))
}
