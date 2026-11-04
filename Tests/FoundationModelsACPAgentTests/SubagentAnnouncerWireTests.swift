import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

extension SubagentAnnouncerTests {
  /// What the agent sends to the client for an agent run.
  @Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct Wire {
    /// The prefix of the folders of each fixture of this suite.
    private static let label = "SubagentAnnouncerTests"

    /// The completion token of the `agents` call of a held run.
    private static let token = "01HELDAGENTSCALLTOKEN00001"

    /// The id that the SDK gives the `agents` call of a held run.
    private static let sdkCallId = "sdk-call-of-the-agents-tool"

    /// One `subagent_update` on the wire.
    private struct Announcement {
      /// The session that the notification names: the parent.
      let parent: SessionId

      /// The update.
      let update: SubagentUpdate
    }

    /// The first text of a slow run. It is the first session event of the
    /// run, and the run holds after it.
    private static let startedText = "STARTED-TEXT"

    /// The script of the runs of this suite. The slow run gives one text delta, so its session
    /// has an event. Then it holds until the test releases it. The root session starts the slow
    /// run when its prompt names it.
    ///
    /// - Parameter hold: The hold that the slow run waits on.
    /// - Returns: The script.
    private static func makeScript(hold: ScriptedHold) -> [ScriptedPassStep] {
      [
        .onPrompt(
          containing: AgentsToolTests.slowRunPrompt,
          play: [
            .textDelta(startedText), .holdUntilReleased(hold),
            .textDelta(AgentsToolTests.slowFinalText), .endPass,
          ]),
        .onPrompt(
          containing: AgentsToolTests.rootSlowPrompt,
          play: [
            AgentsToolTests.startAgentCall(
              agent: AgentsToolTests.slowAgent, prompt: AgentsToolTests.slowRunPrompt),
            .endPass,
          ]),
        .endPass,
      ]
    }

    /// Wires an agent whose root session can start the slow agent, with
    /// a clock that never ends the settle period.
    ///
    /// - Parameter hold: The hold that the slow run waits on.
    /// - Returns: The fixture.
    /// - Throws: Whatever the fixture throws.
    private static func makeFixture(hold: ScriptedHold) async throws -> ScriptedPromptFixture {
      let cwd = makeResolvedDirectory(label: "\(label)-repo")
      try AgentsToolTests.writeAgent(named: AgentsToolTests.slowAgent, in: cwd)
      return try await ScriptedPromptFixture.make(
        script: makeScript(hold: hold), label: label, workingDirectory: cwd,
        runClock: ManualRunClock())
    }

    /// A fixture with a script that only ends its pass.
    ///
    /// - Returns: The fixture.
    /// - Throws: Whatever the fixture throws.
    private static func makeIdleFixture() async throws -> ScriptedPromptFixture {
      try await ScriptedPromptFixture.make(script: [.endPass], label: label)
    }

    /// The announcer of the root session of a fixture.
    ///
    /// - Parameter fixture: The fixture.
    /// - Returns: The announcer.
    /// - Throws: A failed requirement when the root session has no
    ///   `agents` mount.
    private static func announcer(of fixture: ScriptedPromptFixture) async throws
      -> SubagentAnnouncer
    {
      try #require(
        await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents?.announcer)
    }

    /// The join table of a session.
    ///
    /// - Parameters:
    ///   - sessionId: The session.
    ///   - fixture: The fixture.
    /// - Returns: The table.
    /// - Throws: A failed requirement when the session is not in the table.
    private static func joins(of sessionId: SessionId, in fixture: ScriptedPromptFixture)
      async throws
      -> RunCallJoinTable
    {
      try #require(await fixture.harness.agent.sessions[sessionId]?.projector.runCallJoins)
    }

    /// The run id of the root session of a fixture.
    ///
    /// - Parameter fixture: The fixture.
    /// - Returns: The id.
    /// - Throws: A failed requirement when the id is not a ULID.
    private static func rootRun(of fixture: ScriptedPromptFixture) throws -> ULID {
      try #require(ULID(ulidString: fixture.sessionId.rawValue))
    }

    /// Starts a host-driven run of the slow agent, which holds.
    ///
    /// - Parameter fixture: The fixture.
    /// - Returns: The run.
    /// - Throws: Whatever the start throws.
    private static func startSlowRun(in fixture: ScriptedPromptFixture) async throws -> AgentRun {
      let agents = try #require(
        await fixture.harness.agent.sessions[fixture.sessionId]?.surface.agents)
      return try await agents.runner.start(
        AgentsToolTests.slowAgent, prompt: AgentsToolTests.slowRunPrompt)
    }

    /// The `subagent_update` of a notification.
    ///
    /// - Parameter notification: The notification.
    /// - Returns: The announcement, or `nil` for another update.
    private static func announcement(in notification: UpdateSessionNotification) -> Announcement? {
      if case .subagentUpdate(let update) = notification.update {
        return Announcement(parent: notification.sessionId, update: update)
      }
      return nil
    }

    /// The link to the tool call that an announcement carries.
    ///
    /// - Parameter update: The announcement.
    /// - Returns: The link, or `nil` when the announcement has none.
    private static func link(of update: SubagentUpdate) -> SAH.AgentRun? {
      if case .value(let meta) = update.meta {
        return SAH.AgentRun.extract(from: meta)
      }
      return nil
    }

    /// The announcements of a sequence, in wire order.
    ///
    /// - Parameter updates: The collected notifications.
    /// - Returns: The announcements.
    private static func announcements(in updates: [UpdateSessionNotification]) -> [Announcement] {
      updates.compactMap(announcement(in:))
    }

    /// The announcements of one child, in wire order.
    ///
    /// - Parameters:
    ///   - child: The id of the child.
    ///   - updates: The collected notifications.
    /// - Returns: The announcements of the child.
    private static func announcements(
      of child: SessionId, in updates: [UpdateSessionNotification]
    ) -> [Announcement] {
      announcements(in: updates).filter { $0.update.sessionId == child }
    }

    /// Whether a notification uses the id of `child`. It is on the session of the child, or it
    /// is an update for the child.
    ///
    /// - Parameters:
    ///   - notification: The notification.
    ///   - child: The id of the child.
    /// - Returns: `true` when it names the child.
    private static func names(_ notification: UpdateSessionNotification, child: SessionId) -> Bool {
      notification.sessionId == child || announcement(in: notification)?.update.sessionId == child
    }

    /// The ACP id of a run.
    ///
    /// - Parameter run: The run.
    /// - Returns: The id of its session.
    private static func sessionId(of run: AgentRun) -> SessionId {
      SessionId(rawValue: run.id.description)
    }

    /// Releases the hold, then closes the fixture.
    ///
    /// - Parameters:
    ///   - fixture: The fixture.
    ///   - hold: The hold of the slow run.
    private static func finish(_ fixture: ScriptedPromptFixture, releasing hold: ScriptedHold) async
    {
      hold.release()
      await fixture.close()
    }

    /// Sends one message on the root session and waits until it is on the
    /// wire. Each update that the agent sent before is on the wire then,
    /// because the connection keeps the order.
    ///
    /// - Parameters:
    ///   - fixture: The fixture.
    ///   - count: How many such messages are on the wire after this call.
    /// - Returns: The notifications on the wire.
    /// - Throws: A failed wait.
    private static func barrier(_ fixture: ScriptedPromptFixture, count: Int) async throws
      -> [UpdateSessionNotification]
    {
      await fixture.harness.agent.historySink(for: fixture.sessionId)(
        SessionSetupNestedTests.makeMessageUpdate())
      let root = fixture.sessionId
      return try await fixture.collector.wait(for: "the barrier message \(count)") { updates in
        updates.filter { notification in
          if notification.sessionId == root, case .agentMessageChunk = notification.update {
            return true
          }
          return false
        }.count >= count
      }
    }

    /// A nested session whose announcement waits for the join entry of its `agents` call. The
    /// root join table has no entry for the token.
    private struct HeldLink {
      /// The fixture.
      let fixture: ScriptedPromptFixture

      /// The announcer of the root session.
      let announcer: SubagentAnnouncer

      /// The join table of the root session.
      let joins: RunCallJoinTable

      /// The nested session.
      let child: SessionId
    }

    /// Makes a nested session and its report with the token, and waits
    /// until the announcer waits in the join table.
    ///
    /// - Returns: The held link.
    /// - Throws: Whatever the setup throws.
    private static func makeHeldLink() async throws -> HeldLink {
      let fixture = try await makeIdleFixture()
      let announcer = try await announcer(of: fixture)
      let joins = try await joins(of: fixture.sessionId, in: fixture)
      let child = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: fixture.sessionId)
      let report = SubagentAnnouncerTests.makeReport(
        runID: try #require(ULID(ulidString: child.rawValue)), caller: try rootRun(of: fixture),
        completionToken: token)

      announcer.observe(report)
      await waitForWaiter(in: joins)

      return HeldLink(fixture: fixture, announcer: announcer, joins: joins, child: child)
    }

    // MARK: The first message

    /// The first wire message that uses the id of a child is the `subagent_update` for that id.
    /// It goes out on the parent session.
    @Test
    func theFirstMessageOfAChildIsItsSubagentUpdateOnTheParent() async throws {
      let hold = ScriptedHold()
      let fixture = try await Self.makeFixture(hold: hold)
      let child = Self.sessionId(of: try await Self.startSlowRun(in: fixture))

      let updates = try await fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: child, in: $0).isEmpty
      }

      let first = try #require(updates.first { Self.names($0, child: child) })
      #expect(first.sessionId == fixture.sessionId)
      #expect(Self.announcement(in: first)?.update.sessionId == child)
      await Self.finish(fixture, releasing: hold)
    }

    /// The announcement names the agent, its description, the cancel capability and the running
    /// state. It omits the place. The run has no public working directory, and the place of the
    /// parent is not the place of the child. A run that no tool call started has no link.
    @Test
    func theAnnouncementCarriesTheFieldsOfTheRun() async throws {
      let hold = ScriptedHold()
      let fixture = try await Self.makeFixture(hold: hold)
      let child = Self.sessionId(of: try await Self.startSlowRun(in: fixture))

      let updates = try await fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: child, in: $0).isEmpty
      }

      let update = try #require(Self.announcements(of: child, in: updates).first).update
      #expect(update.title == .value(AgentsToolTests.slowAgent))
      #expect(update.description == .value("The \(AgentsToolTests.slowAgent) test agent."))
      #expect(
        update.capabilities
          == .value(SubagentSessionCapabilities(cancel: SessionCancelCapabilities())))
      #expect(update.state == .value(.running(RunningStateUpdate())))
      #expect(update.cwd == .unchanged)
      #expect(update.additionalDirectories == .unchanged)
      #expect(update.meta == .unchanged)
      await Self.finish(fixture, releasing: hold)
    }

    /// The retained history of the parent holds the announcement, so a
    /// `session/resume` of the parent replays it.
    @Test
    func theRetainedHistoryOfTheParentHoldsTheAnnouncement() async throws {
      let hold = ScriptedHold()
      let fixture = try await Self.makeFixture(hold: hold)
      let child = Self.sessionId(of: try await Self.startSlowRun(in: fixture))
      _ = try await fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: child, in: $0).isEmpty
      }

      let history = try #require(await fixture.harness.agent.sessions[fixture.sessionId]?.history)

      #expect(history.subagents.map(\.sessionId) == [child])
      await Self.finish(fixture, releasing: hold)
    }

    // MARK: The link

    /// The announcement of a run that an `agents` call started names the tool call id. That id
    /// is on the wire for that call.
    @Test
    func theAnnouncementLinksTheToolCallThatStartedTheRun() async throws {
      let hold = ScriptedHold()
      let fixture = try await Self.makeFixture(hold: hold)
      let prompt = Task {
        try await fixture.harness.connection.prompt(
          AgentClientHarness.makePromptRequest(
            sessionId: fixture.sessionId, text: AgentsToolTests.rootSlowPrompt))
      }

      let updates = try await fixture.collector.wait(for: "the linked announcement") { updates in
        Self.announcements(in: updates).contains { $0.update.meta != .unchanged }
      }

      let update = try #require(Self.announcements(in: updates).first).update
      let link = try #require(Self.link(of: update))
      let toolCall = try #require(
        updates.compactMap { notification -> ToolCallUpdate? in
          if case .toolCallUpdate(let call) = notification.update { return call }
          return nil
        }.first)
      #expect(link.toolCallId == toolCall.toolCallId)
      hold.release()
      _ = try await prompt.value
      await fixture.close()
    }

    /// The announcement does not leave before the join entry of its call. After the entry, it
    /// carries the SDK id.
    @Test
    func theAnnouncementWaitsForTheEntryAndCarriesTheSdkId() async throws {
      let held = try await Self.makeHeldLink()
      let early = try await Self.barrier(held.fixture, count: 1)
      #expect(Self.announcements(of: held.child, in: early).isEmpty)

      held.joins.record(toolCallID: Self.sdkCallId, for: RunToken(Self.token))

      let updates = try await held.fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: held.child, in: $0).isEmpty
      }
      let update = try #require(Self.announcements(of: held.child, in: updates).first).update
      #expect(Self.link(of: update)?.toolCallId == ToolCallId(rawValue: Self.sdkCallId))
      await held.fixture.close()
    }

    /// The stop of the projection ends the wait. The call has no join, and its wire id is its
    /// completion token.
    @Test
    func theStopOfTheProjectionAnnouncesWithTheTokenAsWireId() async throws {
      let held = try await Self.makeHeldLink()

      held.joins.closeProjection()

      let updates = try await held.fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: held.child, in: $0).isEmpty
      }
      let update = try #require(Self.announcements(of: held.child, in: updates).first).update
      #expect(Self.link(of: update)?.toolCallId == ToolCallId(rawValue: Self.token))
      await held.fixture.close()
    }

    /// The stop of the announcer ends the wait, and nothing leaves: no
    /// announcement with the token as a link.
    @Test
    func theStopOfTheAnnouncerEndsTheWaitAndSendsNothing() async throws {
      let held = try await Self.makeHeldLink()

      await held.announcer.stop()

      let updates = try await Self.barrier(held.fixture, count: 1)
      #expect(Self.announcements(in: updates).isEmpty)
      await held.fixture.close()
    }

    /// A cancelled wait for the link is not available, and a run of the
    /// host has no link at all.
    @Test
    func theLinkOfARunIsNoneForAHostAndUnavailableWhenCancelled() async throws {
      let fixture = try await Self.makeIdleFixture()
      let agent = fixture.harness.agent
      let joins = try await Self.joins(of: fixture.sessionId, in: fixture)
      let root = fixture.sessionId
      let host = SubagentAnnouncerTests.makeReport()
      let called = SubagentAnnouncerTests.makeReport(
        caller: try Self.rootRun(of: fixture), completionToken: Self.token)
      let waiting = Task { await agent.resolveAgentCallLink(of: called, root: root) }
      await waitForWaiter(in: joins)

      waiting.cancel()

      #expect(await waiting.value == .unavailable)
      #expect(await agent.resolveAgentCallLink(of: host, root: root) == .none)
      await fixture.close()
    }

    /// The link of a run whose parent is not in the table is not
    /// available.
    @Test
    func theLinkOfARunWithoutAParentEntryIsUnavailable() async throws {
      let fixture = try await Self.makeIdleFixture()
      let report = SubagentAnnouncerTests.makeReport(caller: ULID(), completionToken: Self.token)

      let link = await fixture.harness.agent.resolveAgentCallLink(
        of: report, root: fixture.sessionId)

      #expect(link == .unavailable)
      await fixture.close()
    }

    /// A nested run gets the link too. The join table of its parent session
    /// gives the wire id, and the announcement goes on the parent run.
    @Test
    func aNestedRunCarriesTheLinkOfTheCallOfItsParentRun() async throws {
      let fixture = try await Self.makeIdleFixture()
      let announcer = try await Self.announcer(of: fixture)
      let child = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: fixture.sessionId)
      let grandchild = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: child)
      let childRun = try #require(ULID(ulidString: child.rawValue))
      try await Self.joins(of: child, in: fixture).record(
        toolCallID: Self.sdkCallId, for: RunToken(Self.token))
      announcer.observe(
        SubagentAnnouncerTests.makeReport(runID: childRun, caller: try Self.rootRun(of: fixture)))
      announcer.observe(
        SubagentAnnouncerTests.makeReport(
          runID: try #require(ULID(ulidString: grandchild.rawValue)), caller: childRun,
          completionToken: Self.token))

      let updates = try await fixture.collector.wait(for: "the nested announcement") {
        !Self.announcements(of: grandchild, in: $0).isEmpty
      }

      let nested = try #require(Self.announcements(of: grandchild, in: updates).first)
      #expect(nested.parent == child)
      #expect(Self.link(of: nested.update)?.toolCallId == ToolCallId(rawValue: Self.sdkCallId))
      await fixture.close()
    }

    /// A link that is known after the first announcement goes out as a later patch. The patch
    /// has the whole `sah` object and nothing else.
    @Test
    func aLinkThatComesLaterGoesOutAsAPatch() async throws {
      let fixture = try await Self.makeIdleFixture()
      let agent = fixture.harness.agent
      let report = SubagentAnnouncerTests.makeReport()
      let child = SessionId(rawValue: report.runID.description)
      let first = await agent.deliverSubagentReport(
        report, replacing: nil, link: nil, root: fixture.sessionId)
      guard case .sent(let snapshot) = first else {
        Issue.record("The first delivery was not sent: \(first)")
        return
      }

      let second = await agent.deliverSubagentReport(
        report, replacing: snapshot, link: ToolCallId(rawValue: Self.sdkCallId),
        root: fixture.sessionId)

      let updates = try await fixture.collector.wait(for: "the patch") {
        Self.announcements(of: child, in: $0).count == 2
      }
      let linked = try SAH.AgentRun(toolCallId: ToolCallId(rawValue: Self.sdkCallId)).inject(
        into: nil)
      #expect(
        Self.announcements(of: child, in: updates).last?.update
          == SubagentUpdate(sessionId: child, meta: .value(linked)))
      guard case .sent(let linkedSnapshot) = second else {
        Issue.record("The second delivery was not sent: \(second)")
        return
      }
      let third = await agent.deliverSubagentReport(
        report, replacing: linkedSnapshot, link: ToolCallId(rawValue: Self.sdkCallId),
        root: fixture.sessionId)
      #expect(third == .unchanged)
      await fixture.close()
    }

    // MARK: The patch

    /// A run that ended sends its final state at its end, with no further
    /// event. The title, the link and the place stay unchanged, and no
    /// second full announcement goes out.
    @Test
    func theEndOfARunSendsItsFinalState() async throws {
      let hold = ScriptedHold()
      let fixture = try await Self.makeFixture(hold: hold)
      let run = try await Self.startSlowRun(in: fixture)
      let child = Self.sessionId(of: run)
      _ = try await fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: child, in: $0).isEmpty
      }

      hold.release()
      _ = try await run.result()
      let updates = try await fixture.collector.wait(for: "the patch") {
        Self.announcements(of: child, in: $0).count == 2
      }
      await fixture.close()

      let patch = try #require(Self.announcements(of: child, in: updates).last).update
      #expect(
        patch
          == SubagentUpdate(
            sessionId: child, state: .value(.idle(IdleStateUpdate(stopReason: .endTurn)))))
      #expect(Self.announcements(of: child, in: await fixture.collector.updates).count == 2)
    }

    // MARK: The chain

    /// One chain of three sessions: the root, a child and a grandchild.
    /// The child is announced on the root, then the grandchild is
    /// announced on the child.
    @Test
    func aGrandchildIsAnnouncedOnTheChildAfterTheChild() async throws {
      let fixture = try await Self.makeIdleFixture()
      let announcer = try await Self.announcer(of: fixture)
      let child = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: fixture.sessionId)
      let grandchild = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: child)
      let childRun = try #require(ULID(ulidString: child.rawValue))
      let grandchildRun = try #require(ULID(ulidString: grandchild.rawValue))

      announcer.observe(SubagentAnnouncerTests.makeReport(runID: childRun))
      announcer.observe(SubagentAnnouncerTests.makeReport(runID: grandchildRun, caller: childRun))

      let updates = try await fixture.collector.wait(for: "both announcements") {
        Self.announcements(in: $0).count == 2
      }
      let sent = Self.announcements(in: updates)
      #expect(sent.map(\.parent) == [fixture.sessionId, child])
      #expect(sent.map(\.update.sessionId) == [child, grandchild])
      await fixture.close()
    }

    /// A child whose parent is not announced yet waits. The agent sends
    /// nothing for it. It goes out when the parent is announced, with no
    /// new observation of the child.
    @Test
    func aChildWaitsForItsParentToBeAnnounced() async throws {
      let fixture = try await Self.makeIdleFixture()
      let announcer = try await Self.announcer(of: fixture)
      let child = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: fixture.sessionId)
      let grandchild = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: child)
      let childRun = try #require(ULID(ulidString: child.rawValue))
      let grandchildReport = SubagentAnnouncerTests.makeReport(
        runID: try #require(ULID(ulidString: grandchild.rawValue)), caller: childRun)

      announcer.observe(grandchildReport)
      let early = try await Self.barrier(fixture, count: 1)
      #expect(Self.announcements(in: early).isEmpty)
      announcer.observe(SubagentAnnouncerTests.makeReport(runID: childRun))

      let updates = try await fixture.collector.wait(for: "the grandchild") {
        !Self.announcements(of: grandchild, in: $0).isEmpty
      }
      #expect(Self.announcements(in: updates).map(\.update.sessionId) == [child, grandchild])
      await fixture.close()
    }

    /// A child whose parent session is not in the table waits, and the
    /// registration of the parent session sends it.
    @Test
    func aBlockedAnnouncementIsSentWhenItsParentSessionIsRegistered() async throws {
      let fixture = try await Self.makeIdleFixture()
      let agent = fixture.harness.agent
      let announcer = try await Self.announcer(of: fixture)
      let parentSession = try #require(await agent.sessions[fixture.sessionId]?.session)
      let nested = SessionSetupNestedTests.makeNestedRouterSession(below: parentSession)
      let nestedId = SessionId(rawValue: nested.id.description)
      let grandchild = SubagentAnnouncerTests.makeReport(caller: nested.id)
      let grandchildId = SessionId(rawValue: grandchild.runID.description)
      announcer.observe(grandchild)
      announcer.observe(
        SubagentAnnouncerTests.makeReport(runID: nested.id, caller: try Self.rootRun(of: fixture)))
      _ = try await fixture.collector.wait(for: "the announcement of the parent") {
        !Self.announcements(of: nestedId, in: $0).isEmpty
      }

      try await agent.registerNestedSession(nested, parent: fixture.sessionId)

      let updates = try await fixture.collector.wait(for: "the announcement of the grandchild") {
        !Self.announcements(of: grandchildId, in: $0).isEmpty
      }
      #expect(Self.announcements(in: updates).map(\.parent) == [fixture.sessionId, nestedId])
      await fixture.close()
    }

    // MARK: The gate

    /// A session that the agent registers after its announcement starts
    /// with an open gate, because the client knows it already.
    @Test
    func aSessionRegisteredAfterItsAnnouncementStartsOpen() async throws {
      let fixture = try await Self.makeIdleFixture()
      let agent = fixture.harness.agent
      let announcer = try await Self.announcer(of: fixture)
      let parentSession = try #require(await agent.sessions[fixture.sessionId]?.session)
      let nested = SessionSetupNestedTests.makeNestedRouterSession(below: parentSession)
      let child = SessionId(rawValue: nested.id.description)
      announcer.observe(SubagentAnnouncerTests.makeReport(runID: nested.id))
      _ = try await fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: child, in: $0).isEmpty
      }

      try await agent.registerNestedSession(nested, parent: fixture.sessionId)

      #expect(await agent.sessions[child]?.announcement.isOpen == true)
      await fixture.close()
    }

    /// The announcement that goes out in the window of the registration
    /// opens the gate that the session holds. The registration takes the
    /// gate first, and the entry is made later with the same gate.
    @Test
    func anAnnouncementInTheWindowOfTheRegistrationOpensTheGateOfTheEntry() async throws {
      let fixture = try await Self.makeIdleFixture()
      let agent = fixture.harness.agent
      let announcer = try await Self.announcer(of: fixture)
      let parentSession = try #require(await agent.sessions[fixture.sessionId]?.session)
      let nested = SessionSetupNestedTests.makeNestedRouterSession(below: parentSession)
      let child = SessionId(rawValue: nested.id.description)
      let gate = announcer.gate(for: nested.id)

      announcer.observe(SubagentAnnouncerTests.makeReport(runID: nested.id))
      _ = try await fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: child, in: $0).isEmpty
      }
      try await agent.registerNestedSession(nested, parent: fixture.sessionId)

      #expect(gate.isOpen)
      #expect(await agent.sessions[child]?.announcement === gate)
      await fixture.close()
    }

    /// While the announcement waits, no update of the child leaves. After
    /// it, an update of the child goes out, and the first message that
    /// names the child is the announcement.
    @Test
    func noUpdateOfTheChildLeavesBeforeItsAnnouncement() async throws {
      let held = try await Self.makeHeldLink()
      let entry = try #require(await held.fixture.harness.agent.sessions[held.child])
      let racingUpdates = 5
      // A send to a closed gate waits for its own send, so the racing updates run in tasks.
      let racing = (0..<racingUpdates).map { _ in
        Task { await entry.projector.commandSink(SessionSetupNestedTests.makeMessageUpdate()) }
      }
      let early = try await Self.barrier(held.fixture, count: 1)
      #expect(!early.contains { Self.names($0, child: held.child) })

      held.joins.record(toolCallID: Self.sdkCallId, for: RunToken(Self.token))
      _ = try await held.fixture.collector.wait(for: "the announcement") {
        !Self.announcements(of: held.child, in: $0).isEmpty
      }
      for task in racing {
        await task.value
      }
      await entry.projector.commandSink(SessionSetupNestedTests.makeMessageUpdate())
      let updates = try await held.fixture.collector.wait(for: "a message of the child") {
        updates in
        updates.contains { $0.sessionId == held.child }
      }

      let firstIndex = try #require(updates.firstIndex { Self.names($0, child: held.child) })
      #expect(Self.announcement(in: updates[firstIndex])?.update.sessionId == held.child)
      await held.fixture.close()
    }

    /// An update that the closed gate holds back is not lost for the replay. The retained
    /// history of the child keeps it.
    @Test
    func anUpdateHeldBackByTheGateStaysInTheHistoryOfTheChild() async throws {
      let fixture = try await Self.makeIdleFixture()
      let child = try await SessionSetupNestedTests.openNestedSession(
        in: fixture, below: fixture.sessionId)
      let entry = try #require(await fixture.harness.agent.sessions[child])

      // A send to a closed gate waits for its own send, so the update runs in a task.
      let kept = Task {
        await entry.projector.commandSink(SessionSetupNestedTests.makeMessageUpdate())
      }
      while entry.announcement.pendingCount == 0 {
        await Task.yield()
      }

      let updates = try await Self.barrier(fixture, count: 1)
      #expect(!updates.contains { $0.sessionId == child })
      let history = try #require(await fixture.harness.agent.sessions[child]?.history)
      #expect(
        history.transcriptUpdates.filter {
          if case .agentMessage = $0 { return true }
          return false
        }.count == 1)
      entry.announcement.discard()
      await kept.value
      await fixture.close()
    }

    // MARK: The closed cases

    /// A session that is closed gets no announcement.
    @Test
    func aClosedSessionGetsNoAnnouncement() async throws {
      let fixture = try await Self.makeIdleFixture()
      let agent = fixture.harness.agent
      _ = try await fixture.harness.connection.closeSession(
        CloseSessionRequest(sessionId: fixture.sessionId))

      let delivery = await agent.deliverSubagentReport(
        SubagentAnnouncerTests.makeReport(), replacing: nil, link: nil, root: fixture.sessionId)

      #expect(delivery == .blocked)
      await fixture.close()
    }

    /// A session whose connection is gone gets no announcement, and the
    /// retained history keeps nothing of it.
    @Test
    func aSessionWithoutAConnectionGetsNoAnnouncement() async throws {
      let fixture = try await Self.makeIdleFixture()
      let agent = fixture.harness.agent
      let owner = try #require(agent.connections.owner(of: fixture.sessionId))
      agent.connections.remove(owner)

      let delivery = await agent.deliverSubagentReport(
        SubagentAnnouncerTests.makeReport(), replacing: nil, link: nil, root: fixture.sessionId)

      #expect(delivery == .blocked)
      #expect(await agent.sessions[fixture.sessionId]?.history.subagents.isEmpty == true)
      // The agent closed the table row of the connection, so the session/close request cannot
      // reach it. The close of the wire closes the session.
      await fixture.harness.close()
    }

    /// The close of the root session stops the announcer.
    @Test
    func theCloseOfTheSessionStopsTheAnnouncer() async throws {
      let fixture = try await Self.makeIdleFixture()
      let announcer = try await Self.announcer(of: fixture)
      _ = try await fixture.harness.connection.closeSession(
        CloseSessionRequest(sessionId: fixture.sessionId))

      #expect(announcer.isStopped)
      await fixture.close()
    }
  }
}
