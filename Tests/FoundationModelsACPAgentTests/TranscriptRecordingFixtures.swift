import Foundation
import FoundationModels
import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import Testing

// MARK: - Recorded-session fixtures for the transcript read side

// `TranscriptStore` tests need real recorded session directories, because
// no shipped `TranscriptRecorder` is reachable and `TranscriptEvent` has no
// public init. The router records events by diffing
// `backend.transcriptEntries()` after each request, so the stub backend here
// accumulates one `.prompt` and one `.response` entry per request — unlike
// `EchoSessionBackend`, whose empty transcript records nothing.

/// A session backend whose synthetic transcript grows by one `.prompt`
/// and one `.response` entry per request, so a routed session over it
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
    /// The counter of a model with no tokenizer: one token per character.
    var tokenCounter: any TokenCounter { CharacterCountTokenCounter() }

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

/// Makes a router whose sessions record real transcript events.
///
/// - Parameters:
///   - cacheDirectory: Where the router caches. A fresh temporary
///     directory per call keeps runs apart.
///   - recordingsDirectory: The durable transcripts root the router
///     records under when a session names no per-session root.
/// - Returns: The router, over ``TranscriptStubContainer`` models.
func makeRecordingStubRouter(cacheDirectory: URL, recordingsDirectory: URL) -> Router {
    EchoModel.makeRouter(
        cacheDirectory: cacheDirectory,
        recordingsDirectory: recordingsDirectory,
        loader: StubModelLoader(makeLLMContainer: { _ in TranscriptStubContainer() }))
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
    try await resolveStubProfile(
        on: makeRecordingStubRouter(
            cacheDirectory: cacheDirectory, recordingsDirectory: recordingsDirectory))
}

/// One recorded project for the transcript read side and the
/// `session/list` wire tests: the working directory, the resolved
/// recording root, a profile whose sessions record real events, and the
/// session directory of its router, which writes the `index.md` of each
/// session folder.
struct RecordedProjectFixture {
    /// The key of the last-activity instant in the frontmatter of an
    /// `index.md`.
    private static let updatedAtKey = "updatedAt:"

    /// The project working directory.
    let workingDirectory: URL

    /// The resolved recording root the sessions record under.
    let root: URL

    /// The resolved profile whose sessions record.
    let profile: LanguageModelProfile

    /// The session directory of the router of ``profile``: it changes the
    /// record of a live session, and of a closed session under ``root``.
    let directory: RouterSessionDirectory

    /// Drives one recorded root session with one request for each prompt
    /// and returns its id.
    ///
    /// The title and the additional directories go to the record through
    /// the session directory while the session is live, as the agent sets
    /// them. The last-activity instant is written after the close, because
    /// Router stamps each submission with the clock.
    ///
    /// - Parameters:
    ///   - prompts: The prompt texts to send, in order. A session with no
    ///     prompt has no first activity, so it does not list.
    ///   - agentSpawn: The spawn context, or `nil` for a plain root.
    ///   - title: The title of the record, or `nil` for none.
    ///   - additionalDirectories: The additional directories of the record.
    ///   - updatedAt: The last-activity instant of the record, or `nil` for
    ///     the instant Router stamps.
    ///   - sessionWorkingDirectory: The working directory of the session —
    ///     the `cwd` of its record — or `nil` for ``workingDirectory``. A
    ///     shared-root test records sessions of two projects under one root.
    /// - Returns: The session's ULID — the name of its directory.
    /// - Throws: Whatever driving the session, a record change, or the
    ///   rewrite of ``setUpdatedAt(_:ofSession:under:)`` throws.
    func makeRecordedSession(
        prompts: [String] = ["one prompt"],
        agentSpawn: SessionRecord.AgentSpawn? = nil,
        title: String? = nil,
        additionalDirectories: [URL] = [],
        updatedAt: Date? = nil,
        in sessionWorkingDirectory: URL? = nil
    ) async throws -> ULID {
        let session = profile.standard.makeSession(
            workingDirectory: sessionWorkingDirectory ?? workingDirectory,
            recordingRoot: root,
            agentSpawn: agentSpawn)
        for prompt in prompts {
            _ = try await session.respond(to: prompt)
        }
        if let title {
            _ = try await directory.setTitle(title, of: session.id)
        }
        if !additionalDirectories.isEmpty {
            try await directory.setAdditionalDirectories(to: additionalDirectories, for: session.id)
        }
        await session.close()
        if let updatedAt {
            try Self.setUpdatedAt(updatedAt, ofSession: session.id, under: root)
        }
        return session.id
    }

    /// Records one session as a fork of `parent` and returns its id.
    ///
    /// A recorded fork tree keeps the folder of each fork in the folder of
    /// its parent, and Router reads the `parentId` of a session from that
    /// layout. Router still restores such a tree, but a live session can
    /// not fork. So this call records a plain session with
    /// ``makeRecordedSession(prompts:agentSpawn:title:additionalDirectories:updatedAt:in:)``,
    /// and then moves its folder into the folder of `parent`.
    ///
    /// - Parameter parent: The recorded session whose folder gets the fork.
    /// - Returns: The fork's ULID — the name of its directory.
    /// - Throws: Whatever ``makeRecordedSession(prompts:agentSpawn:title:additionalDirectories:updatedAt:in:)``
    ///   or the move throws.
    func makeRecordedFork(of parent: ULID) async throws -> ULID {
        let fork = try await makeRecordedSession(prompts: ["fork prompt"])
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(fork.description, isDirectory: true),
            to: root.appendingPathComponent(parent.description, isDirectory: true)
                .appendingPathComponent(fork.description, isDirectory: true))
        return fork
    }

    /// Rewrites the last-activity instant in the `index.md` of one closed
    /// session folder: the one shared way a test pins `updatedAt`, for a
    /// sort order, a wire value, or a cursor walk.
    ///
    /// Router writes each date as ISO 8601 text in UTC with milliseconds,
    /// so the rewrite writes `date` the same way and keeps the quoting of
    /// the line.
    ///
    /// - Parameters:
    ///   - date: The new last-activity instant.
    ///   - id: The session, whose id names its folder.
    ///   - root: The recording root that holds the folder.
    /// - Throws: The read or the write error, or a failed requirement when
    ///   the frontmatter holds no `updatedAt` date.
    static func setUpdatedAt(_ date: Date, ofSession id: ULID, under root: URL) throws {
        let file = RecordedSessionIndexFile.fileURL(ofSession: id.description, under: root)
        var lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let position = try #require(
            lines.firstIndex { $0.hasPrefix(updatedAtKey) }, "the index.md holds no updatedAt")
        let text = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
        let rewritten = lines[position].replacing(/\d{4}-\d{2}-\d{2}T[0-9:.]+Z/, with: text)
        try #require(rewritten != lines[position], "the updatedAt line holds no date")
        lines[position] = rewritten
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Makes a recorded-project fixture over the given directories.
///
/// The session directory of the fixture's router reads closed sessions
/// from `recordingRoot`, so a test can change the record of a session it
/// already closed.
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
    let router = makeRecordingStubRouter(
        cacheDirectory: cacheDirectory, recordingsDirectory: recordingRoot)
    await router.sessionDirectory.useRecordingRoots { [recordingRoot] }
    return RecordedProjectFixture(
        workingDirectory: workingDirectory,
        root: recordingRoot,
        profile: try await resolveStubProfile(on: router),
        directory: router.sessionDirectory)
}
