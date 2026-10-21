import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The `changes` subscription of the `settings` endpoint (ACPA-17, EXTRAS-9
/// rule 9): one event for each change of the store, from a mutation and from
/// an outside write, with the cursor and the time of the change and the
/// dotted key paths that it added, changed and removed; the `cursor` query
/// and `changes(after:)`, which resumes after a cursor or gives
/// `RESYNC_REQUIRED`; and a subscription that lives on when the store stops
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

    /// The id of `compaction.trigger` in `added`, `changed` and `removed`.
    private static let triggerID = SettingsGraphFixture.triggerKeyPath.joined(separator: ".")

    /// One event of the subscription, as a test reads it.
    private struct ChangeEvent: Equatable {
        /// The `SettingLevel` name of the level that changed.
        var level: String

        /// The working directory of a session level, or `nil` for the user
        /// level.
        var cwd: String?

        /// The changed key path, or `nil` for an outside change.
        var keyPath: [String]?

        /// The dotted key paths that the change added.
        var added: [String] = []

        /// The dotted key paths that the change changed.
        var changed: [String] = []

        /// The dotted key paths that the change removed.
        var removed: [String] = []

        /// Reads the next event of a subscription.
        ///
        /// - Parameter iterator: The iterator of the response of each event.
        /// - Returns: The event.
        /// - Throws: A failed requirement when the stream ends or the
        ///   response has no `changes` object.
        static func next(of iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator) async throws
            -> ChangeEvent
        {
            try ChangeEvent(await nextObject(of: &iterator))
        }

        /// Reads the `changes` object of the next event of a subscription.
        ///
        /// - Parameter iterator: The iterator of the response of each event.
        /// - Returns: The object.
        /// - Throws: A failed requirement when the stream ends or the
        ///   response has no `changes` object.
        static func nextObject(of iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator) async throws
            -> [String: Any]
        {
            let text = try #require(try await iterator.next(), "the subscription ended")
            return try GraphQLReply(text).object("changes")
        }

        /// Makes the event of a `changes` object.
        ///
        /// - Parameter change: The object.
        /// - Throws: A failed requirement when the object has no level.
        init(_ change: [String: Any]) throws {
            level = try #require(change["level"] as? String)
            cwd = change["cwd"] as? String
            keyPath = change["keyPath"] as? [String]
            added = change["added"] as? [String] ?? []
            changed = change["changed"] as? [String] ?? []
            removed = change["removed"] as? [String] ?? []
        }

        /// Makes an event that a test expects.
        ///
        /// - Parameters:
        ///   - level: The `SettingLevel` name of the level that changed.
        ///   - cwd: The working directory of a session level, or `nil`.
        ///   - keyPath: The changed key path, or `nil` for an outside change.
        ///   - added: The dotted key paths that the change added.
        ///   - changed: The dotted key paths that the change changed.
        ///   - removed: The dotted key paths that the change removed.
        init(
            level: String, cwd: String?, keyPath: [String]?, added: [String] = [], changed: [String] = [],
            removed: [String] = []
        ) {
            self.level = level
            self.cwd = cwd
            self.keyPath = keyPath
            self.added = added
            self.changed = changed
            self.removed = removed
        }
    }

    // MARK: - Events

    /// A mutation sends one event that names its level and its key path. The
    /// key had no value, thus the key path is in `added`.
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
                    keyPath: SettingsGraphFixture.triggerKeyPath, added: [Self.triggerID]))
    }

    /// An outside write of the session file sends one event with no key
    /// path, whose `changed` names the key that the write changed. The
    /// subscription watches the session level of its working directory, also
    /// when no call read that level before.
    @Test(.timeLimit(.minutes(1))) func anOutsideFileChangeSendsAChange() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-outside")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.sessionTriggerYAML, in: sessionRoot)
        var changes = try await fixture.changes(cwd: fixture.firstDirectory)

        try ConfigFileFixture.write(Self.outsideTriggerYAML, in: sessionRoot)

        #expect(
            try await ChangeEvent.next(of: &changes)
                == ChangeEvent(
                    level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory.path, keyPath: nil,
                    changed: [Self.triggerID]))
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
                    level: SettingsGraphFixture.userLevel, cwd: nil, keyPath: SettingsGraphFixture.triggerKeyPath,
                    added: [Self.triggerID]))
    }

    /// Two clients subscribe, and each one gets the event of a mutation. The
    /// first client leaves, and its connection stops the watch of the store
    /// (`stopWatching()`, as `tearDownConnection(_:after:)` does). The
    /// subscription of the second client does not end: the store reads its
    /// levels again and sends one event with no key path for each level, with
    /// no id because no key differs from before the stop. Then it sends the
    /// event of a clear and the event of an outside write.
    @Test(.timeLimit(.minutes(1))) func aSubscriptionLivesOnWhenADifferentConnectionCloses() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-two-clients")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.sessionTriggerYAML, in: sessionRoot)
        var first: AsyncThrowingStream<String, Error>.AsyncIterator? =
            try await fixture.changes(cwd: fixture.firstDirectory)
        var second = try await fixture.changes(cwd: fixture.firstDirectory)
        let userChange = ChangeEvent(
            level: SettingsGraphFixture.userLevel, cwd: nil, keyPath: SettingsGraphFixture.triggerKeyPath)
        let session = ChangeEvent(
            level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory.path, keyPath: nil)
        let user = ChangeEvent(level: SettingsGraphFixture.userLevel, cwd: nil, keyPath: nil)
        var added = userChange
        added.added = [Self.triggerID]
        _ = try await fixture.set(
            .number(Number(Self.mutationTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)
        #expect(try await ChangeEvent.next(of: &first!) == added)
        #expect(try await ChangeEvent.next(of: &second) == added)

        first = nil
        await fixture.store.stopWatching()

        #expect(try await ChangeEvent.next(of: &second) == user)
        #expect(try await ChangeEvent.next(of: &second) == session)
        _ = try await fixture.clear(
            SettingsGraphFixture.triggerKeyPath, level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)
        var removed = userChange
        removed.removed = [Self.triggerID]
        #expect(try await ChangeEvent.next(of: &second) == removed)
        try ConfigFileFixture.write(Self.outsideTriggerYAML, in: sessionRoot)
        var outside = session
        outside.changed = [Self.triggerID]
        #expect(try await ChangeEvent.next(of: &second) == outside)
    }

    // MARK: - The cursor

    /// A client reads the cursor, a change happens, and `changes(after:)`
    /// with that cursor gives the change: its key path is in `added`, and the
    /// event has a cursor after the first one and the time of the change.
    @Test(.timeLimit(.minutes(1))) func theChangesAfterACursorGiveTheChange() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-after")
        let cursor = try await fixture.cursor(cwd: fixture.firstDirectory)
        let before = Date()
        _ = try await fixture.set(
            .number(Number(Self.mutationTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)

        var changes = try await fixture.changes(cwd: fixture.firstDirectory, after: cursor)

        let change = try await ChangeEvent.nextObject(of: &changes)
        #expect(
            try ChangeEvent(change)
                == ChangeEvent(
                    level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory.path,
                    keyPath: SettingsGraphFixture.triggerKeyPath, added: [Self.triggerID]))
        let eventCursor = try #require(change["cursor"] as? String)
        #expect(eventCursor != cursor)
        #expect(eventCursor == (try await fixture.cursor(cwd: fixture.firstDirectory)))
        let at = try DateTime(rfc3339: try #require(change["at"] as? String))
        #expect(at >= DateTime(before))
    }

    /// A set of a key that has a value puts its key path in `changed`, and a
    /// clear puts it in `removed`.
    @Test(.timeLimit(.minutes(1))) func aSetOfAKeyWithAValueIsChangedAndAClearIsRemoved() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-kinds")
        let cursor = try await fixture.cursor(cwd: nil)
        for trigger in [Self.mutationTrigger, Self.outsideTrigger] {
            _ = try await fixture.set(
                .number(Number(trigger)), at: SettingsGraphFixture.triggerKeyPath,
                level: SettingsGraphFixture.userLevel, cwd: nil)
        }
        _ = try await fixture.clear(SettingsGraphFixture.triggerKeyPath, level: SettingsGraphFixture.userLevel, cwd: nil)

        var changes = try await fixture.changes(cwd: nil, after: cursor)

        let user = ChangeEvent(
            level: SettingsGraphFixture.userLevel, cwd: nil, keyPath: SettingsGraphFixture.triggerKeyPath)
        var added = user
        added.added = [Self.triggerID]
        var changed = user
        changed.changed = [Self.triggerID]
        var removed = user
        removed.removed = [Self.triggerID]
        #expect(try await ChangeEvent.next(of: &changes) == added)
        #expect(try await ChangeEvent.next(of: &changes) == changed)
        #expect(try await ChangeEvent.next(of: &changes) == removed)
    }

    /// A read of the cursor with a working directory starts the watch of its
    /// session level, thus an outside write after the read is in the changes
    /// after the cursor.
    @Test(.timeLimit(.minutes(1))) func aCursorWithAWorkingDirectoryWatchesItsSessionLevel() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-cursor-watch")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.sessionTriggerYAML, in: sessionRoot)
        let cursor = try await fixture.cursor(cwd: fixture.firstDirectory)

        try ConfigFileFixture.write(Self.outsideTriggerYAML, in: sessionRoot)
        var changes = try await fixture.changes(cwd: fixture.firstDirectory, after: cursor)

        #expect(
            try await ChangeEvent.next(of: &changes)
                == ChangeEvent(
                    level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory.path, keyPath: nil,
                    changed: [Self.triggerID]))
    }

    // MARK: - RESYNC_REQUIRED

    /// A cursor of another store, which is another epoch of the change log,
    /// gives `RESYNC_REQUIRED`, and the subscription then ends.
    @Test(.timeLimit(.minutes(1))) func aCursorOfAnotherStoreGivesResyncRequired() async throws {
        let fixture = try SettingsGraphFixture(label: "subscription-epoch")
        let other = try SettingsGraphFixture(label: "subscription-epoch-other")
        let cursor = try await other.cursor(cwd: nil)

        var changes = try await fixture.changes(cwd: nil, after: cursor)

        let text = try #require(try await changes.next(), "the subscription gave no response")
        #expect(try GraphQLReply(text).codes == [GraphQLToolkitError.resyncRequired(reason: "").code])
        #expect(try await changes.next() == nil)
    }

    /// A cursor whose next change left the change log, which keeps only the
    /// newest change here, gives `RESYNC_REQUIRED`, and the subscription then
    /// ends.
    @Test(.timeLimit(.minutes(1))) func aTooOldCursorGivesResyncRequired() async throws {
        let fixture = try SettingsGraphFixture(
            label: "subscription-too-old", secretStore: InMemorySecretStore([:]), changeCapacity: 1)
        let cursor = try await fixture.cursor(cwd: nil)
        for trigger in [Self.mutationTrigger, Self.outsideTrigger] {
            _ = try await fixture.set(
                .number(Number(trigger)), at: SettingsGraphFixture.triggerKeyPath,
                level: SettingsGraphFixture.userLevel, cwd: nil)
        }

        var changes = try await fixture.changes(cwd: nil, after: cursor)

        let text = try #require(try await changes.next(), "the subscription gave no response")
        #expect(try GraphQLReply(text).codes == [GraphQLToolkitError.resyncRequired(reason: "").code])
        #expect(try await changes.next() == nil)
    }
}
