import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The tests of three parts of the announcer.
/// The first part keeps the events for the projector of a child session.
/// The second part looks up the live session of a run.
/// The third part is the end of the run. The outputs end, the child settles, and the hold
/// on the final status of its `agents` call ends.
extension SubagentAnnouncerTests {
  /// The outputs, the session lookup and the end of a run, with an outlet that records what it gets.
  @Suite(.timeLimit(.minutes(1))) struct Outputs {
    /// The root session of the outlets of this suite.
    private static let root = SessionId(rawValue: ULID().description)

    /// The completion token of the `agents` call of a run.
    private static let token = "01OUTPUTSTESTCALLTOKEN0001"

    /// The sources that the first delivery of a run got, in order.
    private typealias Sources = WatchedValue<[SubagentSource]>

    /// The final reports that the outlet settled, in order.
    private typealias Settlements = WatchedValue<[SubagentReport]>

    /// One text event as a session sends it.
    ///
    /// - Parameter text: The text.
    /// - Returns: The output.
    private static func output(_ text: String) -> SessionOutput {
      SessionOutput(origin: .system, event: .textDelta(text))
    }

    /// A live Router session that stands for the session of a run.
    ///
    /// - Returns: The session.
    /// - Throws: Whatever the stub profile throws.
    private static func makeSession() async throws -> any RoutedSession {
      let profile = try await makeStubProfile(
        cacheDirectory: makeResolvedDirectory(label: "SubagentAnnouncerOutputTests-cache"))
      return profile.standard.makeSession(
        workingDirectory: makeResolvedDirectory(label: "SubagentAnnouncerOutputTests-repo"),
        recordingRoot: makeResolvedDirectory(label: "SubagentAnnouncerOutputTests-root"))
    }

    /// Makes an outlet that records the source of the first delivery of each run and the
    /// settlements.
    ///
    /// - Parameters:
    ///   - sources: The sources of the deliveries.
    ///   - settlements: The final reports that the outlet settled.
    ///   - holds: The holds that a settlement releases, as the real outlet does.
    ///   - session: What the directory finds for a run.
    ///   - link: What the outlet finds as the link of a run.
    /// - Returns: The outlet.
    private static func makeOutlet(
      sources: Sources, settlements: Settlements = Settlements([]), holds: AgentCallHolds? = nil,
      session: @escaping @Sendable (ULID) -> (any RoutedSession)? = { _ in nil },
      link: @escaping @Sendable (SubagentReport) async -> SubagentLink = { _ in .none }
    ) -> SubagentOutlet {
      SubagentOutlet(
        root: root,
        link: link,
        deliver: { report, _, _, source in
          if let source {
            sources.update { $0.append(source) }
          }
          return .sent(SubagentAnnouncerTests.makeSnapshot(of: report))
        },
        session: session,
        settle: { report in
          if let token = report.completionToken {
            _ = holds?.release(token)
          }
          settlements.update { $0.append(report) }
        },
        parentReport: { _ in nil })
    }

    /// Observes one event of a run through the closure form of the hook.
    ///
    /// - Parameters:
    ///   - announcer: The announcer.
    ///   - report: The report of the run.
    ///   - text: The text of the event.
    private static func observe(
      _ announcer: SubagentAnnouncer, _ report: SubagentReport, _ text: String
    ) {
      announcer.observe(
        runID: report.runID, output: output(text), watchEnd: {}, makeReport: { report })
    }

    /// Reads each output of a stream until it ends.
    ///
    /// - Parameter source: The source of the run.
    /// - Returns: The outputs, in order.
    private static func drain(_ source: SubagentSource) async -> [SessionOutput] {
      var outputs: [SessionOutput] = []
      for await next in source.outputs {
        outputs.append(next)
      }
      return outputs
    }

    // MARK: The order and the end of the outputs

    /// The outputs of a run reach the projector of its child in the order of the events.
    /// They start at the first event.
    @Test
    func theKeptOutputsKeepTheOrderOfTheEvents() async throws {
      let session = try await Self.makeSession()
      let announcer = SubagentAnnouncer()
      let sources = Sources([])
      announcer.bind(Self.makeOutlet(sources: sources, session: { _ in session }))
      let report = SubagentAnnouncerTests.makeReport()

      for text in ["a", "b", "c"] {
        Self.observe(announcer, report, text)
      }
      let source = try await sources.wait(for: "the first delivery") { !$0.isEmpty }[0]
      await announcer.stop()

      #expect(await Self.drain(source).map(Self.text) == ["a", "b", "c"])
      await session.close()
    }

    /// The text of an output, for a comparison.
    ///
    /// - Parameter output: The output.
    /// - Returns: The text of a text event, or an empty string.
    private static func text(of output: SessionOutput) -> String {
      if case .textDelta(let text) = output.event { return text }
      return ""
    }

    /// The announcer asks the directory for the session once, when it finds it.
    @Test
    func theSessionIsLookedUpOnceWhenTheDirectoryFindsIt() async throws {
      let session = try await Self.makeSession()
      let announcer = SubagentAnnouncer()
      let sources = Sources([])
      let lookups = Mutex(0)
      announcer.bind(
        Self.makeOutlet(
          sources: sources,
          session: { _ in
            lookups.withLock { $0 += 1 }
            return session
          }))
      let report = SubagentAnnouncerTests.makeReport()

      for text in ["a", "b", "c"] {
        Self.observe(announcer, report, text)
      }
      _ = try await sources.wait(for: "the first delivery") { !$0.isEmpty }

      #expect(lookups.withLock { $0 } == 1)
      await announcer.stop()
      await session.close()
    }

    /// The directory has no session at the first event, and has it at the next event. The
    /// child is announced with its session, and it keeps its content.
    @Test
    func aSessionThatAppearsAtALaterEventIsFound() async throws {
      let session = try await Self.makeSession()
      let announcer = SubagentAnnouncer()
      let sources = Sources([])
      let known = Mutex<(any RoutedSession)?>(nil)
      let linkReleased = WatchedValue(false)
      announcer.bind(
        Self.makeOutlet(
          sources: sources, session: { _ in known.withLock { $0 } },
          link: { _ in
            _ = try? await linkReleased.wait(for: "the link") { $0 }
            return .callId(ToolCallId(rawValue: "call"))
          }))
      let report = SubagentAnnouncerTests.makeReport(completionToken: Self.token)

      Self.observe(announcer, report, "first")
      known.withLock { $0 = session }
      Self.observe(announcer, report, "second")
      linkReleased.update { $0 = true }

      let source = try await sources.wait(for: "the first delivery") { !$0.isEmpty }[0]
      #expect(source.session.id == session.id)
      await announcer.stop()
      await session.close()
    }

    /// The events come before the bind, so nobody asked the directory. The delivery asks it, so
    /// the child is announced with its session.
    @Test
    func aSessionThatAppearsBeforeTheDeliveryIsFound() async throws {
      let session = try await Self.makeSession()
      let announcer = SubagentAnnouncer()
      let sources = Sources([])
      let report = SubagentAnnouncerTests.makeReport()
      Self.observe(announcer, report, "before the bind")

      announcer.bind(Self.makeOutlet(sources: sources, session: { _ in session }))

      let source = try await sources.wait(for: "the first delivery") { !$0.isEmpty }[0]
      #expect(source.session.id == session.id)
      await announcer.stop()
      await session.close()
    }

    /// A run that no reader drains keeps a bounded number of outputs. At the bound, the oldest
    /// output leaves, and the announcer counts what it dropped.
    @Test
    func theOutputsOfARunKeepTheNewestOnesAtTheBound() async throws {
      let session = try await Self.makeSession()
      let announcer = SubagentAnnouncer(outputLimit: 3)
      let sources = Sources([])
      announcer.bind(Self.makeOutlet(sources: sources, session: { _ in session }))
      let report = SubagentAnnouncerTests.makeReport()

      for text in ["a", "b", "c", "d", "e"] {
        Self.observe(announcer, report, text)
      }
      let source = try await sources.wait(for: "the first delivery") { !$0.isEmpty }[0]
      let dropped = announcer.droppedOutputCount(of: report.runID)
      await announcer.stop()

      #expect(await Self.drain(source).map(Self.text) == ["c", "d", "e"])
      #expect(dropped == 2)
      await session.close()
    }

    /// The outputs of a run end when its state is dropped.
    /// So the projector of the child reads to the end.
    @Test
    func theOutputsEndWhenTheRunEnds() async throws {
      let session = try await Self.makeSession()
      let announcer = SubagentAnnouncer()
      let sources = Sources([])
      announcer.bind(Self.makeOutlet(sources: sources, session: { _ in session }))
      let report = SubagentAnnouncerTests.makeReport()
      Self.observe(announcer, report, "a")
      let source = try await sources.wait(for: "the first delivery") { !$0.isEmpty }[0]

      announcer.observe(
        SubagentAnnouncerTests.makeReport(
          runID: report.runID, state: SubagentAnnouncerTests.endedState),
        isFinal: true)

      #expect(await Self.drain(source).map(Self.text) == ["a"])
      await announcer.stop()
      await session.close()
    }

    // MARK: The stop

    /// The stop ends the outputs of a run that is live. It settles the run and releases its hold.
    /// So the final status of its call goes out, and the projector of the child ends.
    @Test
    func theStopEndsTheOutputsSettlesTheLiveRunsAndReleasesTheHolds() async throws {
      let session = try await Self.makeSession()
      let announcer = SubagentAnnouncer()
      let sources = Sources([])
      let settlements = Settlements([])
      announcer.bind(
        Self.makeOutlet(
          sources: sources, settlements: settlements, holds: announcer.holds,
          session: { _ in session }))
      let report = SubagentAnnouncerTests.makeReport(completionToken: Self.token)
      announcer.holds.runObserved(Self.token)
      announcer.holds.hold(Self.token)
      Self.observe(announcer, report, "a")
      let source = try await sources.wait(for: "the first delivery") { !$0.isEmpty }[0]

      await announcer.stop()

      #expect(await Self.drain(source).map(Self.text) == ["a"])
      #expect(settlements.value.map(\.runID) == [report.runID])
      #expect(announcer.holds.heldCount == 0)
      await session.close()
    }

    // MARK: The order of the hold and the end

    /// A run that ended at its first event leaves no hold. The hold of the call comes after the
    /// end of the run, so it is not placed. The final status of the call is not kept for ever.
    @Test
    func aRunThatEndedAtItsFirstEventLeavesNoHold() async throws {
      let announcer = SubagentAnnouncer()
      let settlements = Settlements([])
      announcer.bind(
        Self.makeOutlet(sources: Sources([]), settlements: settlements, holds: announcer.holds))
      let running = SubagentAnnouncerTests.makeReport(completionToken: Self.token)
      let ended = SubagentAnnouncerTests.makeReport(
        runID: running.runID, state: SubagentAnnouncerTests.endedState, completionToken: Self.token)

      announcer.observe(
        runID: running.runID, output: Self.output("a"),
        watchEnd: { announcer.observe(ended, isFinal: true) }, makeReport: { running })
      _ = try await settlements.wait(for: "the settlement") { !$0.isEmpty }
      announcer.holds.hold(Self.token)

      #expect(announcer.holds.heldCount == 0)
      await announcer.stop()
    }
  }
}
