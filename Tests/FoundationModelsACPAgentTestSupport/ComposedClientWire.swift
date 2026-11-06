// `ComposedClientWire` — a client of the client library, in this process,
// against a composed agent, over an in-memory wire that comes down with the
// teardown of the agent.
//
// The suites of the composed agent, of the client library interop and of the
// skills marketplace all run the same sequence: serve, connect, run the
// requests, close both ends, and wait for the agent. This one home keeps the
// sequence, so the suites keep only their own assertions.

import Foundation
import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPClient

/// The in-memory wire between a client and a composed agent.
public enum ComposedClientWire {
  /// Runs `requests` from a client on `clientEnd`, then closes the wire and
  /// waits for the teardown of the agent.
  ///
  /// - Parameters:
  ///   - clientEnd: The client end of the wire.
  ///   - agentEnd: The agent end of the wire.
  ///   - agentConnection: The connection that serves the agent on
  ///     `agentEnd`.
  ///   - composed: The composition that `agentConnection` serves.
  ///   - requests: The requests that the client sends over its connection.
  /// - Returns: The value that `requests` gives.
  /// - Throws: Whatever `requests` throws.
  public static func exchange<Value: Sendable>(
    over clientEnd: InMemoryTransport,
    closing agentEnd: InMemoryTransport,
    served agentConnection: AgentSideConnection,
    by composed: ComposedAgent,
    _ requests: (ClientSideConnection) async throws -> Value
  ) async throws -> Value {
    let model = await ConnectionModel()
    let connection = await model.connect(over: clientEnd)
    // Swift has no asynchronous `defer`, and the wire must come down on
    // the failing path as well, so the outcome is held here and given
    // back after the teardown.
    let outcome: Result<Value, any Error>
    do {
      outcome = .success(try await requests(connection))
    } catch {
      outcome = .failure(error)
    }
    await connection.close()
    await agentConnection.close()
    clientEnd.close()
    agentEnd.close()
    await composed.waitForConnectionTeardown()
    await composed.closeOpenSessions()
    return try outcome.get()
  }

  /// Serves `composed` over a new in-memory wire, sends `initialize` and
  /// `session/new` in `workspace` from a client, runs `body` with the open
  /// session, and then closes the wire and waits for the teardown of the
  /// agent.
  ///
  /// A teardown that does not end holds the caller, and the time limit of
  /// the suite ends it.
  ///
  /// - Parameters:
  ///   - composed: The composition that serves the client.
  ///   - workspace: The working directory of the session.
  ///   - body: What the suite does with the open session. It gets the client
  ///     end of the connection and the id of the session.
  /// - Returns: The value that `body` gives.
  /// - Throws: Whatever the handshake, the session call or `body` throws.
  public static func withSession<Value: Sendable>(
    of composed: ComposedAgent,
    in workspace: URL,
    _ body: (ClientSideConnection, SessionId) async throws -> Value
  ) async throws -> Value {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConnection = await composed.serve(over: agentEnd)
    return try await exchange(
      over: clientEnd, closing: agentEnd, served: agentConnection, by: composed
    ) { connection in
      _ = try await connection.initialize(AgentClientHarness.makeInitializeRequest())
      let session = try await connection.newSession(
        NewSessionRequest(cwd: AbsolutePath(rawValue: workspace.path)))
      return try await body(connection, session.sessionId)
    }
  }
}
