import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import acp_agent

/// The session event lines of `--verbose`, and the silence of `--quiet`
/// (cli-plan.md §5.7).
///
/// Five claims stand here. `--verbose` projects each session event to one
/// line, in arrival order, and it projects nothing else: the answer text
/// belongs to stdout, and a state update that is not the turn's end is not
/// an event a person asked for. The lines hold no ANSI escape, so a piped
/// run is something a person greps. `--quiet` writes no line and draws no
/// download bar, in a terminal too, and the one error writer of the binary
/// keeps its own path out. Neither flag writes nothing at all. And stdout
/// carries the same bytes under each of the four flag combinations,
/// because none of this touches file descriptor 1.
struct EventLineWriterTests {
    // MARK: - Constants

    /// The id of the first scripted tool call.
    private static let firstToolCallId = ToolCallId(rawValue: "call-first")

    /// The id of the second scripted tool call.
    private static let secondToolCallId = ToolCallId(rawValue: "call-second")

    /// The name the first scripted tool call carries.
    private static let firstToolName = "readFile"

    /// The name the second scripted tool call carries.
    private static let secondToolName = "runCode"

    /// The content of the plan entry the scripted plan update is working
    /// on, so the plan line names a task and not only a count.
    private static let currentPlanTask = "write the failing test"

    /// The id of the scripted plan.
    private static let planId = PlanId(rawValue: "plan-first")

    /// The message id every scripted answer chunk shares.
    private static let messageId = MessageId(rawValue: "message-first")

    /// The text of the scripted answer chunk, which belongs to stdout and
    /// must reach no event line.
    private static let answerText = "an answer that stderr never carries"

    /// The prompt of every run in this suite.
    private static let promptText = "write a haiku"

    /// The text the scripted model streams as its one delta.
    private static let scriptedAnswer = "an answer over the in-process pair"

    /// The name of the session tool the scripted turn calls. `wait` takes
    /// an empty argument object, needs no model, and returns at once when
    /// no background run is pending, so a turn that calls it twice costs
    /// no weights and no waiting.
    private static let scriptedToolName = "wait"

    /// The arguments of each scripted tool call: the empty object.
    private static let scriptedToolArguments = "{}"

    /// How many tool calls the scripted turn makes.
    private static let scriptedToolCallCount = 2

    /// The escape sequence introducer no event line may hold.
    private static let ansiIntroducer = "\u{001B}["

    /// The message beside the progress bar the download card draws.
    private static let progressMessage = "downloading the standard model"

    /// The fraction the progress bar test reports.
    private static let reportedFraction = 0.5

    /// The count of bytes the progress bar test reports as complete.
    private static let completedBytes: Int64 = 512

    /// The count of bytes the progress bar test reports in total.
    private static let totalBytes: Int64 = 1024

    // MARK: - Fixtures

    /// The four scripted session events the card names: two tool calls,
    /// one plan update, and the stop reason.
    ///
    /// - Returns: The events, in the order a turn sends them.
    private static func scriptedEvents() -> [SessionUpdate] {
        [
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: firstToolCallId,
                    status: .value(.inProgress),
                    title: .value(firstToolName))),
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: secondToolCallId,
                    status: .value(.inProgress),
                    title: .value(secondToolName))),
            .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: planEntries, planId: planId)))),
            .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))),
        ]
    }

    /// The entries of the scripted plan: one done, one being worked on,
    /// and one still to do.
    private static let planEntries = [
        PlanEntry(content: "read the card", priority: .high, status: .completed),
        PlanEntry(content: currentPlanTask, priority: .high, status: .inProgress),
        PlanEntry(content: "run the suite", priority: .medium, status: .pending),
    ]

    /// The lines the four scripted events project to, in order.
    private static let scriptedLines = [
        "\(EventLineWriter.toolLineKind) \(firstToolCallId.rawValue) in_progress \(firstToolName)",
        "\(EventLineWriter.toolLineKind) \(secondToolCallId.rawValue) in_progress \(secondToolName)",
        "\(EventLineWriter.planLineKind) 1/\(planEntries.count) \(currentPlanTask)",
        "\(EventLineWriter.stopLineKind) end_turn",
    ]

    /// The session events that carry no line: the answer text, which
    /// stdout owns, and the state update that starts the turn.
    private static func unprojectedEvents() -> [SessionUpdate] {
        [
            .agentMessageChunk(
                ContentChunk(content: .text(TextContent(text: answerText)), messageId: messageId)),
            .stateUpdate(.running(RunningStateUpdate())),
        ]
    }

    /// Writes `events` to a fresh capture at `verbosity`, and gives back
    /// what reached the capture.
    ///
    /// - Parameters:
    ///   - events: The session events to project.
    ///   - verbosity: The verbosity of the writer.
    /// - Returns: The captured text.
    private static func project(
        _ events: [SessionUpdate], at verbosity: EventVerbosity
    ) -> String {
        let capture = TerminalCapture()
        var writer = EventLineWriter(destination: capture.destination, verbosity: verbosity)
        for event in events {
            writer.receive(event)
        }
        return capture.text()
    }

    /// The lines of `text`, with the empty line the final newline leaves
    /// removed.
    ///
    /// - Parameter text: The captured text.
    /// - Returns: The lines, in write order.
    private static func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The tool call ids the `tool` lines of `lines` name.
    ///
    /// - Parameter lines: The captured lines.
    /// - Returns: The distinct ids.
    private static func toolCallIds(in lines: [String]) -> Set<String> {
        Set(
            lines
                .filter { $0.hasPrefix("\(EventLineWriter.toolLineKind) ") }
                .compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) })
    }

    /// Runs one scripted turn that calls a session tool twice, and gives
    /// back what each stream carried.
    ///
    /// - Parameters:
    ///   - verbosity: The verbosity of the run's event lines.
    ///   - label: The directory label, so a leftover directory says where
    ///     it came from.
    /// - Returns: The stderr text and the stdout bytes of the turn.
    /// - Throws: Whatever the composition or the turn throws.
    private static func runScriptedTurn(
        at verbosity: EventVerbosity, label: String
    ) async throws -> (standardError: String, standardOutput: Data) {
        let workspace = makeResolvedDirectory(label: "\(label)-repo")
        let composed = try await CLICompositionFixture.scripted(
            script: toolTurnScript, label: label)
        let answer = try AnswerCapture(label: "\(label)-answer")
        let capture = TerminalCapture()

        _ = try await RunTurn.answer(
            of: composed,
            in: .new(workingDirectory: workspace),
            prompt: promptText,
            into: answer.writer,
            reporting: EventLineWriter(destination: capture.destination, verbosity: verbosity))

        return (standardError: capture.text(), standardOutput: try answer.bytes())
    }

    /// The script of a turn that calls one session tool twice and then
    /// streams its answer.
    private static let toolTurnScript: [ScriptedTurnStep] = [
        .toolCall(name: scriptedToolName, argumentsJSON: scriptedToolArguments),
        .toolCall(name: scriptedToolName, argumentsJSON: scriptedToolArguments),
        .textDelta(scriptedAnswer),
        .endTurn,
    ]

    // MARK: - The flags select the verbosity (cli-plan.md §5.4)

    /// The two flags of `run` select the three verbosities, and `--quiet`
    /// wins when both are given: it asks for silence, and silence is the
    /// answer a person can undo by running again.
    @Test func theTwoFlagsSelectTheVerbosity() {
        #expect(EventVerbosity(verbose: false, quiet: false) == .normal)
        #expect(EventVerbosity(verbose: true, quiet: false) == .verbose)
        #expect(EventVerbosity(verbose: false, quiet: true) == .quiet)
        #expect(EventVerbosity(verbose: true, quiet: true) == .quiet)
    }

    /// `run` reads its own two flags into the verbosity, so the parse and
    /// the writer cannot disagree.
    @Test func theParsedFlagsReachTheVerbosity() throws {
        let quiet = try #require(
            try AcpAgentCommand.parseAsRoot(["run", "--quiet", Self.promptText])
                as? AcpAgentCommand.Run)
        let verbose = try #require(
            try AcpAgentCommand.parseAsRoot(["run", "--verbose", Self.promptText])
                as? AcpAgentCommand.Run)
        let plain = try #require(
            try AcpAgentCommand.parseAsRoot(["run", Self.promptText]) as? AcpAgentCommand.Run)

        #expect(quiet.eventVerbosity == .quiet)
        #expect(verbose.eventVerbosity == .verbose)
        #expect(plain.eventVerbosity == .normal)
    }

    // MARK: - `--verbose`: one line for each event (cli-plan.md §5.7)

    /// Two tool calls, one plan update and a stop reason give four lines,
    /// in the order the events arrived.
    @Test func verboseWritesOneLineForEachSessionEvent() {
        let captured = Self.project(Self.scriptedEvents(), at: .verbose)

        #expect(Self.lines(of: captured) == Self.scriptedLines)
    }

    /// The answer text and the running state update carry no line. The
    /// answer belongs to stdout (§5.6), and a turn that started is not one
    /// of the three events §5.7 names.
    @Test func verboseWritesNoLineForTheAnswerOrTheRunningState() {
        let captured = Self.project(Self.unprojectedEvents(), at: .verbose)

        #expect(captured.isEmpty)
    }

    /// A tool call update that carries no status and no title still gets
    /// its line, with the absent-field mark in place of each value the
    /// event did not carry. One event, one line, whatever the event holds.
    @Test func verboseMarksEachFieldTheEventDidNotCarry() {
        let update = SessionUpdate.toolCallUpdate(
            ToolCallUpdate(toolCallId: Self.firstToolCallId))

        let captured = Self.project([update], at: .verbose)

        #expect(
            Self.lines(of: captured) == [
                "\(EventLineWriter.toolLineKind) \(Self.firstToolCallId.rawValue) "
                    + "\(EventLineWriter.absentField) \(EventLineWriter.absentField)"
            ])
    }

    /// The name of a tool call reaches every later line of that call. The
    /// agent names the tool on the creation update alone, so a writer that
    /// forgot it would report a status with no name.
    @Test func verboseNamesTheToolOnEachLineOfTheCall() {
        let events: [SessionUpdate] = [
            .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: Self.firstToolCallId,
                    status: .value(.inProgress),
                    title: .value(Self.firstToolName))),
            .toolCallUpdate(
                ToolCallUpdate(toolCallId: Self.firstToolCallId, status: .value(.completed))),
        ]

        let captured = Self.project(events, at: .verbose)

        #expect(
            Self.lines(of: captured) == [
                "\(EventLineWriter.toolLineKind) \(Self.firstToolCallId.rawValue) in_progress "
                    + Self.firstToolName,
                "\(EventLineWriter.toolLineKind) \(Self.firstToolCallId.rawValue) completed "
                    + Self.firstToolName,
            ])
    }

    /// The lines hold no ANSI escape, in a pipe and in a terminal alike,
    /// so a piped `--verbose` run is something a person greps.
    @Test func verboseHoldsNoAnsiEscape() {
        let captured = Self.project(Self.scriptedEvents(), at: .verbose)

        #expect(!captured.isEmpty)
        #expect(!captured.contains(Self.ansiIntroducer))
    }

    // MARK: - `--quiet` and the default (cli-plan.md §5.7)

    /// `--quiet` writes no event line, whatever the turn sent.
    @Test func quietWritesNoEventLine() {
        let captured = Self.project(Self.scriptedEvents(), at: .quiet)

        #expect(captured.isEmpty)
    }

    /// `--quiet` writes nothing BUT the error. The event writer stays
    /// silent, and the one error writer of the binary keeps its own path
    /// to stderr, which no flag of `run` reaches.
    @Test func quietWritesOnlyTheError() {
        let failure = UnknownResumedSessionError(sessionId: Self.firstToolCallId.rawValue)

        let captured = Self.project(Self.scriptedEvents(), at: .quiet)
        let outcome = AcpAgentCommand.exitOutcome(for: failure)

        #expect(captured.isEmpty)
        #expect(outcome.writesToStandardError)
        #expect(AcpAgentCommand.fullMessage(for: failure).contains(failure.description))
    }

    /// Neither flag writes zero bytes: a successful run says nothing on
    /// stderr, so a person who asked for an answer gets an answer.
    @Test func neitherFlagWritesAnyLine() {
        let captured = Self.project(Self.scriptedEvents(), at: .normal)

        #expect(captured.isEmpty)
    }

    // MARK: - `--quiet` turns the download bar off (cli-plan.md §5.7)

    /// `--quiet` draws no download bar, in a terminal too. The renderer
    /// takes its terminal test as an argument, and the verbosity is half
    /// of that test.
    @Test func quietDrawsNoProgressBarInATerminal() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(
            destination: capture.destination,
            isTerminal: EventVerbosity.quiet.drawsProgress)

        try await renderer.progressBar(message: Self.progressMessage) { report in
            report(
                Self.progressMessage,
                Self.reportedFraction,
                TerminalRenderer.ByteProgress(
                    completed: Self.completedBytes, total: Self.totalBytes))
        }

        #expect(capture.bytes().isEmpty)
    }

    /// Without `--quiet` the bar draws in a terminal, so the case above
    /// measures the flag and not a renderer that draws nothing.
    @Test func theDefaultDrawsTheProgressBarInATerminal() async throws {
        let capture = TerminalCapture()
        let renderer = TerminalRenderer(
            destination: capture.destination,
            isTerminal: EventVerbosity.normal.drawsProgress)

        try await renderer.progressBar(message: Self.progressMessage) { report in
            report(
                Self.progressMessage,
                Self.reportedFraction,
                TerminalRenderer.ByteProgress(
                    completed: Self.completedBytes, total: Self.totalBytes))
        }

        #expect(!capture.bytes().isEmpty)
    }

    // MARK: - One whole turn over a pipe (cli-plan.md §5.7)

    /// A `--verbose` run whose turn makes two tool calls writes one line
    /// for each event and nothing else: every line is a projected event,
    /// the two calls are the two the script made, and the turn's one stop
    /// reason stands last. In a pipe, because a person asked to see them.
    @Test(.timeLimit(.minutes(2)))
    func aVerbosePipedRunWritesOneLineForEachEvent() async throws {
        let streams = try await Self.runScriptedTurn(
            at: .verbose, label: "EventLineWriterTests-verbose")

        let lines = Self.lines(of: streams.standardError)
        #expect(!lines.isEmpty)
        #expect(
            lines.allSatisfy { line in
                line.hasPrefix("\(EventLineWriter.toolLineKind) ")
                    || line.hasPrefix("\(EventLineWriter.planLineKind) ")
                    || line.hasPrefix("\(EventLineWriter.stopLineKind) ")
            })
        #expect(Self.toolCallIds(in: lines).count == Self.scriptedToolCallCount)
        #expect(lines.count { $0.hasPrefix("\(EventLineWriter.stopLineKind) ") } == 1)
        #expect(lines.last == "\(EventLineWriter.stopLineKind) end_turn")
        #expect(!streams.standardError.contains(Self.ansiIntroducer))
        #expect(!streams.standardError.contains(Self.scriptedAnswer))
    }

    /// A run with neither flag writes zero bytes to stderr, over the same
    /// turn that fills the stream under `--verbose`.
    @Test(.timeLimit(.minutes(2)))
    func aPipedRunWithNeitherFlagWritesZeroBytesToStandardError() async throws {
        let streams = try await Self.runScriptedTurn(
            at: .normal, label: "EventLineWriterTests-plain")

        #expect(streams.standardError.isEmpty)
    }

    /// stdout carries the same bytes under each of the four flag
    /// combinations. §5.6 stays byte-exact, because none of §5.7 touches
    /// file descriptor 1.
    @Test(.timeLimit(.minutes(4)))
    func standardOutputIsIdenticalAcrossTheFourFlagCombinations() async throws {
        var written: [Data] = []
        for (index, flags) in Self.flagCombinations.enumerated() {
            let streams = try await Self.runScriptedTurn(
                at: EventVerbosity(verbose: flags.verbose, quiet: flags.quiet),
                label: "EventLineWriterTests-stdout-\(index)")
            written.append(streams.standardOutput)
        }

        #expect(written.count == Self.flagCombinations.count)
        #expect(written.first == Data(Self.scriptedAnswer.utf8))
        #expect(written.allSatisfy { $0 == written.first })
    }

    /// The four combinations of the two flags of §5.4.
    private static let flagCombinations = [
        (verbose: false, quiet: false),
        (verbose: true, quiet: false),
        (verbose: false, quiet: true),
        (verbose: true, quiet: true),
    ]
}
