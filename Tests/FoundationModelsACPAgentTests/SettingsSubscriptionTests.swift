import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The `changes` subscription of the `settings` endpoint (ACPA-17): one event
/// for each change of ``SettingsStore/changes()``, from a mutation and from
/// an outside write, and a subscription that lives on when the store stops
/// for the close of a different connection.
@Suite struct SettingsSubscriptionTests {
    /// The value of `compaction.trigger` that a mutation sets.
    private static let mutationTrigger = 0.7

    /// The value of `compaction.trigger` that the session file holds first.
    private static let sessionTrigger = 0.9

    /// The value of `compaction.trigger` that an outside write sets.
    private static let outsideTrigger = 0.8

    /// A session `config.yaml` that sets `compaction.trigger` to
    /// ``sessionTrigger``.
    private static let sessionTriggerYAML = "compaction:\n  trigger: \(sessionTrigger)\n"

    /// A session `config.yaml` that sets `compaction.trigger` to
    /// ``outsideTrigger``.
    private static let outsideTriggerYAML = "compaction:\n  trigger: \(outsideTrigger)\n"

    /// One event of the subscription, as a test reads it.
    private struct ChangeEvent: Equatable {
        /// The `SettingLevel` name of the level that changed.
        let level: String

        /// The working directory of a session level, or `nil` for the user
        /// level.
        let cwd: String?

        /// The changed key path, or `nil` for an outside change.
        let keyPath: [String]?

        /// Reads the next event of a subscription.
        ///
        /// - Parameter iterator: The iterator of the response of each event.
        /// - Returns: The event.
        /// - Throws: A failed requirement when the stream ends or the
        ///   response has no `changes` object.
        static func next(of iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator) async throws
            -> ChangeEvent
        {
            let text = try #require(try await iterator.next(), "the subscription ended")
            let change = try GraphQLReply(text).object("changes")
            return ChangeEvent(
                level: try #require(change["level"] as? String), cwd: change["cwd"] as? String,
                keyPath: change["keyPath"] as? [String])
        }
    }

    /// A mutation sends one event that names its level and its key path.
    @Test(.timeLimit(.minutes(1))) func aMutationSendsAChange() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-mutation")
        var changes = try await fixture.changes(cwd: fixture.firstDirectory)

        _ = try await fixture.set(
            .number(Number(Self.mutationTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)

        #expect(
            try await ChangeEvent.next(of: &changes)
                == ChangeEvent(
                    level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory.path,
                    keyPath: SettingsGraphFixture.triggerKeyPath))
    }

    /// An outside write of the session file sends one event with no key
    /// path. The subscription watches the session level of its working
    /// directory, also when no call read that level before.
    @Test(.timeLimit(.minutes(1))) func anOutsideFileChangeSendsAChange() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-outside")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.sessionTriggerYAML, in: sessionRoot)
        var changes = try await fixture.changes(cwd: fixture.firstDirectory)

        try ConfigFileFixture.write(Self.outsideTriggerYAML, in: sessionRoot)

        #expect(
            try await ChangeEvent.next(of: &changes)
                == ChangeEvent(
                    level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory.path, keyPath: nil))
    }

    /// A subscription with no working directory gives the changes of the
    /// user level only. A session level change comes first and the
    /// subscription does not send it, thus the first event is the event of
    /// the user level change that a call with no `cwd` made.
    @Test(.timeLimit(.minutes(1))) func aSubscriptionWithNoWorkingDirectoryGivesTheUserLevelChanges() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-user")
        var changes = try await fixture.changes(cwd: nil)

        _ = try await fixture.set(
            .number(Number(Self.sessionTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)
        _ = try await fixture.set(
            .number(Number(Self.mutationTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: nil)

        #expect(
            try await ChangeEvent.next(of: &changes)
                == ChangeEvent(
                    level: SettingsGraphFixture.userLevel, cwd: nil, keyPath: SettingsGraphFixture.triggerKeyPath))
    }

    /// Two clients subscribe, and each one gets the event of a mutation. The
    /// first client leaves, and its connection stops the watch of the store
    /// (`stopWatching()`, as `closeOpenSessions(after:)` does). The
    /// subscription of the second client does not end: it reads its levels
    /// again and sends one event with no key path for each level, and then
    /// it sends the event of a second mutation and the event of an outside
    /// write.
    @Test(.timeLimit(.minutes(1))) func aSubscriptionLivesOnWhenADifferentConnectionCloses() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-two-clients")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.sessionTriggerYAML, in: sessionRoot)
        var first: AsyncThrowingStream<String, Error>.AsyncIterator? =
            try await fixture.changes(cwd: fixture.firstDirectory)
        var second = try await fixture.changes(cwd: fixture.firstDirectory)
        let mutation = ChangeEvent(
            level: SettingsGraphFixture.userLevel, cwd: nil, keyPath: SettingsGraphFixture.triggerKeyPath)
        let session = ChangeEvent(
            level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory.path, keyPath: nil)
        let user = ChangeEvent(level: SettingsGraphFixture.userLevel, cwd: nil, keyPath: nil)
        _ = try await fixture.set(
            .number(Number(Self.mutationTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)
        #expect(try await ChangeEvent.next(of: &first!) == mutation)
        #expect(try await ChangeEvent.next(of: &second) == mutation)

        first = nil
        await fixture.store.stopWatching()

        #expect(try await ChangeEvent.next(of: &second) == user)
        #expect(try await ChangeEvent.next(of: &second) == session)
        _ = try await fixture.clear(
            SettingsGraphFixture.triggerKeyPath, level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)
        #expect(try await ChangeEvent.next(of: &second) == mutation)
        try ConfigFileFixture.write(Self.outsideTriggerYAML, in: sessionRoot)
        #expect(try await ChangeEvent.next(of: &second) == session)
    }
}
