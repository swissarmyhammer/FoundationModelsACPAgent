import Foundation
import FoundationModels
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
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
        loader: StubModelLoader(makeLLMContainer: { _ in TranscriptStubContainer() }))
}

/// One recorded project for the transcript read side and the
/// `session/list` wire tests: the working directory, the resolved
/// recording root, a profile whose sessions record real events, and the
/// root's `sessions.jsonl` index.
struct RecordedProjectFixture {
    /// The project working directory.
    let workingDirectory: URL

    /// The resolved recording root the sessions record under.
    let root: URL

    /// The resolved profile whose sessions record.
    let profile: LanguageModelProfile

    /// The `sessions.jsonl` index of the root.
    let index: SessionIndex

    /// Drives one recorded root session with one turn for each prompt
    /// and returns its id.
    ///
    /// - Parameters:
    ///   - prompts: The turns to drive, in order.
    ///   - agentSpawn: The spawn context, or `nil` for a plain root.
    /// - Returns: The session's ULID — the name of its directory.
    /// - Throws: Whatever driving the session throws.
    func makeRecordedSession(
        prompts: [String] = ["one turn"],
        agentSpawn: SessionSidecar.AgentSpawn? = nil
    ) async throws -> ULID {
        let session = profile.standard.makeSession(
            workingDirectory: workingDirectory,
            recordingRoot: root,
            agentSpawn: agentSpawn)
        for prompt in prompts {
            _ = try await session.respond(to: prompt)
        }
        await session.close()
        return session.id
    }

    /// Appends one index record that names `id`.
    ///
    /// - Parameters:
    ///   - id: The session the record names.
    ///   - title: The record's title.
    ///   - updatedAt: The record's most-recent-activity instant.
    ///   - additionalDirectories: The record's ordered directory list.
    ///   - cwd: The record's working directory, or `nil` for the
    ///     fixture's own. A shared-root test writes records that name
    ///     two different projects into one index.
    /// - Throws: Whatever the index append throws.
    func appendRecord(
        id: ULID,
        title: String,
        updatedAt: Date,
        additionalDirectories: [String] = [],
        cwd: URL? = nil
    ) throws {
        try index.append(
            SessionIndexRecord(
                sessionId: id.description,
                cwd: (cwd ?? workingDirectory).standardizedFileURL.path,
                title: title,
                updatedAt: updatedAt,
                additionalDirectories: additionalDirectories))
    }
}

/// Makes a recorded-project fixture over the given directories.
///
/// - Parameters:
///   - workingDirectory: The project working directory.
///   - cacheDirectory: The router cache directory. A fresh temporary
///     directory for each call keeps runs apart.
///   - recordingRoot: The resolved recording root the sessions record
///     under.
/// - Returns: The fixture. It retains its profile, and the profile
///   retains its router.
/// - Throws: Whatever profile resolution throws.
func makeRecordedProjectFixture(
    workingDirectory: URL, cacheDirectory: URL, recordingRoot: URL
) async throws -> RecordedProjectFixture {
    RecordedProjectFixture(
        workingDirectory: workingDirectory,
        root: recordingRoot,
        profile: try await makeRecordingStubProfile(
            cacheDirectory: cacheDirectory, recordingsDirectory: recordingRoot),
        index: SessionIndex(root: recordingRoot))
}
