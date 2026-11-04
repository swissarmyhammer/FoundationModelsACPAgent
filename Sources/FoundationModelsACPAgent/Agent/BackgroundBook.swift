import FoundationModelsACP

/// One change of the work that runs apart from the foreground work of a session. The sources of
/// the work send these changes to the state ledger of the session.
///
/// A source sends a change only after the wire update that it names went out. So the book lists an
/// item after its announcement, and it drops the item after its final status.
enum BackgroundChange: Equatable, Sendable {
  /// A `tool_call_update` for the call went to the client.
  case callAnnounced(ToolCallId)

  /// The SDK call returned, and its run goes on. The run is background work.
  case callDetached(ToolCallId)

  /// The run of the call settled, and the final status of the call went to the client.
  case callSettled(ToolCallId)

  /// The announce of the terminal of a run went to the client, on the tool call of the run.
  case terminalAnnounced(TerminalId, on: ToolCallId)

  /// The exit status of the terminal went to the client.
  case terminalExited(TerminalId)

  /// The `subagent_update` of a child went to the client.
  case subagentAnnounced(SessionId)

  /// The child session works (`true`), or it is idle with no background work (`false`).
  case subagentActivity(SessionId, isActive: Bool)

  /// The child session is gone.
  case subagentRetired(SessionId)
}

/// The list of the work that runs apart from the foreground work of one session.
///
/// A tool call is listed from its detach, once the client knows it. A call whose terminal is
/// running is listed as that terminal, not as the call. A child session is listed while it is
/// active, once the client knows it. The book keeps only facts, so the order of the changes of
/// two sources does not matter.
struct BackgroundBook: Equatable, Sendable {
  /// The calls that the client knows.
  private var announcedCalls: Set<ToolCallId> = []

  /// The calls whose run goes on after the SDK call returned, in the order of the detach.
  private var detachedCalls: [ToolCallId] = []

  /// The terminal of each call that has one.
  private var terminalsByCall: [ToolCallId: TerminalId] = [:]

  /// The terminals whose exit status went to the client.
  private var exitedTerminals: Set<TerminalId> = []

  /// The children that the client knows, in the order of the announcements.
  private var announcedChildren: [SessionId] = []

  /// The children that work now.
  private var activeChildren: Set<SessionId> = []

  /// The list that the book gives now.
  var list: [BackgroundWork] {
    detachedCalls.compactMap(entry(of:))
      + announcedChildren.filter(activeChildren.contains).map {
        .subagent(BackgroundSubagent(sessionId: $0))
      }
  }

  /// Takes one change into the book.
  ///
  /// - Parameter change: The change.
  mutating func apply(_ change: BackgroundChange) {
    switch change {
    case .callAnnounced(let call):
      announcedCalls.insert(call)
    case .callDetached(let call):
      if !detachedCalls.contains(call) {
        detachedCalls.append(call)
      }
    case .callSettled(let call):
      forget(call)
    case .terminalAnnounced(let terminal, let call):
      announcedCalls.insert(call)
      terminalsByCall[call] = terminal
    case .terminalExited(let terminal):
      exitedTerminals.insert(terminal)
    case .subagentAnnounced(let child):
      if !announcedChildren.contains(child) {
        announcedChildren.append(child)
      }
    case .subagentActivity(let child, let isActive):
      if isActive {
        activeChildren.insert(child)
      } else {
        activeChildren.remove(child)
      }
    case .subagentRetired(let child):
      announcedChildren.removeAll { $0 == child }
      activeChildren.remove(child)
    }
  }

  /// Drops a call and its terminal from the book.
  ///
  /// - Parameter call: The call whose run settled.
  private mutating func forget(_ call: ToolCallId) {
    announcedCalls.remove(call)
    detachedCalls.removeAll { $0 == call }
    if let terminal = terminalsByCall.removeValue(forKey: call) {
      exitedTerminals.remove(terminal)
    }
  }

  /// The list entry of a detached call.
  ///
  /// - Parameter call: The call.
  /// - Returns: The terminal while it runs, else the call. `nil` while the client does not know
  ///   the call.
  private func entry(of call: ToolCallId) -> BackgroundWork? {
    guard announcedCalls.contains(call) else {
      return nil
    }
    if let terminal = terminalsByCall[call], !exitedTerminals.contains(terminal) {
      return .terminal(BackgroundTerminal(terminalId: terminal))
    }
    return .toolCall(BackgroundToolCall(toolCallId: call))
  }
}

extension StateUpdate {
  /// This state with a background list.
  ///
  /// - Parameter list: The list that the state carries.
  /// - Returns: The state with the list. A state that this revision does not know stays as it is.
  func reporting(background list: [BackgroundWork]) -> StateUpdate {
    switch self {
    case .running(var running):
      running.background = list
      return .running(running)
    case .idle(var idle):
      idle.background = list
      return .idle(idle)
    case .requiresAction(var action):
      action.background = list
      return .requiresAction(action)
    case .unknown:
      return self
    }
  }
}
