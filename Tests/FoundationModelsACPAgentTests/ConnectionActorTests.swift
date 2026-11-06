import FoundationModelsACP
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The person that a connection acts as (ACPA-13, EXTRAS-5). The
/// credential of the connection decides it, never the client: a `userDevice`
/// connection may claim an identity in the `_meta` of `initialize`, and an
/// `external` connection never gets the identity that it claims.
@Suite struct ConnectionActorTests {
  /// The local user of the tests: fixed, so no test reads the machine.
  private static let localUser = LocalUser(userName: "casey", fullName: "Casey Example")

  /// The identity that a client claims.
  private static let claimed = GraphQLActor(
    id: "icloud/ABC", name: "Pat Person", aliases: ["local/pat"])

  /// The connection of the tests.
  private static let connection = ConnectionId(rawValue: "connection-1")

  /// A `userDevice` connection with a valid claim acts as the claimed
  /// actor.
  @Test
  func aUserDeviceClaimIsAccepted() {
    let table = Self.makeTable(trust: .userDevice)

    table.recordActorClaim(Self.claimed, of: Self.connection)

    #expect(table.viewer(of: Self.connection).actor == Self.claimed)
  }

  /// A `userDevice` connection with no claim acts as the local user of the
  /// agent process.
  @Test
  func aUserDeviceWithNoClaimGetsTheLocalUser() {
    let table = Self.makeTable(trust: .userDevice)

    table.recordActorClaim(nil, of: Self.connection)

    #expect(
      table.viewer(of: Self.connection).actor
        == GraphQLActor(id: "local/casey", name: "Casey Example"))
  }

  /// A claim that does not decode reads as no claim (`fromMeta` gives
  /// `nil` for it), so the connection gets the local user.
  @Test
  func aBadClaimGetsTheLocalUser() {
    let table = Self.makeTable(trust: .userDevice)
    let bad: JSONValue = .object([GraphQLActor.initializeMetaKey: .string("not an actor")])

    table.recordActorClaim(GraphQLActor.fromMeta(bad), of: Self.connection)

    #expect(table.viewer(of: Self.connection).actor?.id == "local/casey")
  }

  /// An `external` connection never gets the claimed identity: it acts as
  /// `external/<id>`, with a name that the server makes.
  @Test
  func anExternalClaimIsRefused() {
    let table = Self.makeTable(trust: .external)

    table.recordActorClaim(Self.claimed, of: Self.connection)

    #expect(
      table.viewer(of: Self.connection).actor
        == GraphQLActor(
          id: "external/connection-1", name: "External client connection-1"))
  }

  /// The direct caller has no actor, and a connection with no row has none.
  @Test
  func theDirectCallerAndAClosedConnectionHaveNoActor() {
    let table = Self.makeTable(trust: .userDevice)

    table.recordActorClaim(Self.claimed, of: .direct)
    table.recordActorClaim(Self.claimed, of: ConnectionId(rawValue: "unknown"))

    #expect(table.viewer(of: .direct).actor == nil)
    #expect(table.viewer(of: ConnectionId(rawValue: "unknown")).actor == nil)
  }

  /// A second `initialize` replaces the actor: the last claim wins.
  @Test
  func theLastClaimWins() {
    let table = Self.makeTable(trust: .userDevice)
    let other = GraphQLActor(id: "icloud/XYZ", name: "Sam Second")

    table.recordActorClaim(Self.claimed, of: Self.connection)
    table.recordActorClaim(other, of: Self.connection)

    #expect(table.viewer(of: Self.connection).actor == other)
  }

  /// Makes a table with one row of `trust` and the fixed local user.
  private static func makeTable(trust: ConnectionTrust) -> ConnectionTable {
    let table = ConnectionTable(localUser: localUser)
    table.add(nil, id: connection, trust: trust)
    return table
  }
}
