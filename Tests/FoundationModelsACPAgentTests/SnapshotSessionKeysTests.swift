import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The maps of ``SnapshotSessionKeys`` between the ACP session and the
/// Router sessions that serve it: the host session of each Router session
/// that replaced the first one on a model-slot switch, and the live store
/// owner of the ACP session.
///
/// Each test makes its own map, so no test reads the map of the process.
@Suite struct SnapshotSessionKeysTests {
    /// The ACP session, which is the id of its first Router session too.
    private static let acpSession = SessionId(rawValue: "01M5M8ACPSESSION0000000000")

    /// The Router session of the first model-slot switch.
    private static let firstReplacement = "01M5M8FIRSTREPLACEMENT0000"

    /// The Router session of the second model-slot switch.
    private static let secondReplacement = "01M5M8SECONDREPLACEMENT000"

    /// The session key of the ACP session.
    private static let sessionKey = "SnapshotSessionKeysTests-key"

    /// A replacement maps its Router id to the ACP session, and the ACP
    /// session to the replacement as its live store owner.
    @Test
    func aReplacementMapsItsRouterIdToTheACPSessionAndBack() {
        let keys = SnapshotSessionKeys()

        keys.recordReplacement(Self.firstReplacement, of: Self.acpSession)

        #expect(keys.hostSession(of: Self.firstReplacement) == Self.acpSession.rawValue)
        #expect(keys.storeOwner(of: Self.acpSession.rawValue) == Self.firstReplacement)
    }

    /// A session that no switch replaced has no mapping: the endpoints keep
    /// its own id.
    @Test
    func aSessionWithNoSwitchHasNoMapping() {
        let keys = SnapshotSessionKeys()

        keys.record(Self.sessionKey, for: Self.acpSession)

        #expect(keys.hostSession(of: Self.acpSession.rawValue) == nil)
        #expect(keys.storeOwner(of: Self.acpSession.rawValue) == nil)
    }

    /// A second switch makes the second replacement the live store owner,
    /// and both replacements keep the ACP session as their host session.
    @Test
    func aSecondSwitchMovesTheLiveOwnerAndKeepsEachHostSession() {
        let keys = SnapshotSessionKeys()

        keys.recordReplacement(Self.firstReplacement, of: Self.acpSession)
        keys.recordReplacement(Self.secondReplacement, of: Self.acpSession)

        #expect(keys.storeOwner(of: Self.acpSession.rawValue) == Self.secondReplacement)
        #expect(keys.hostSession(of: Self.firstReplacement) == Self.acpSession.rawValue)
        #expect(keys.hostSession(of: Self.secondReplacement) == Self.acpSession.rawValue)
    }

    /// The release of the live Router session forgets the live store owner,
    /// and keeps the host session, so the checkpoints of the replacement
    /// still name the ACP session.
    @Test
    func aReleaseForgetsTheLiveOwnerAndKeepsTheHostSession() {
        let keys = SnapshotSessionKeys()
        keys.recordReplacement(Self.firstReplacement, of: Self.acpSession)

        keys.forgetLiveOwner(of: Self.acpSession)

        #expect(keys.storeOwner(of: Self.acpSession.rawValue) == nil)
        #expect(keys.hostSession(of: Self.firstReplacement) == Self.acpSession.rawValue)
    }

    /// The delete of the ACP session forgets its key, its live store owner,
    /// and the host session of each of its replacements.
    @Test
    func aDeleteForgetsEachMapOfTheSession() {
        let keys = SnapshotSessionKeys()
        keys.record(Self.sessionKey, for: Self.acpSession)
        keys.recordReplacement(Self.firstReplacement, of: Self.acpSession)
        keys.recordReplacement(Self.secondReplacement, of: Self.acpSession)

        keys.forget(Self.acpSession)

        #expect(keys.sessionKey(of: Self.acpSession.rawValue) == nil)
        #expect(keys.storeOwner(of: Self.acpSession.rawValue) == nil)
        #expect(keys.hostSession(of: Self.firstReplacement) == nil)
        #expect(keys.hostSession(of: Self.secondReplacement) == nil)
    }
}
