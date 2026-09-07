import Foundation
import FoundationModelsACP

/// How much of a `run` turn the stderr stream carries (cli-plan.md §5.7).
///
/// Two flags of §5.4 select one of these three, and everything the CLI
/// writes to stderr reads its answer here. stdout is not in the picture:
/// the answer of the turn owns file descriptor 1 (§5.6), and no value of
/// this type moves a byte of it.
enum EventVerbosity: Sendable, Equatable {
    /// `--quiet`: no event line and no download bar, in a terminal too.
    ///
    /// The error keeps its own path. ``AcpAgentCommand`` writes every
    /// failure to stderr when the process ends, and no flag of `run`
    /// reaches that writer, so a quiet run still says why it failed.
    case quiet

    /// Neither flag: no event line, and the download bar in a terminal.
    ///
    /// A successful run says nothing at all on a pipe, so `acp-agent run
    /// "hi" 2>errors.txt` leaves an empty file.
    case normal

    /// `--verbose`: one line for each session event, in a pipe too.
    ///
    /// A person who asks to see the events is asking for data, not for
    /// decoration, so the lines go out whether or not stderr is a
    /// terminal.
    case verbose

    /// The verbosity the two flags of `run` select (cli-plan.md §5.4).
    ///
    /// `--quiet` wins when both flags are given. The two ask for
    /// opposite things, and the quieter answer is the one a person can
    /// undo by running again; a stream a person did not want cannot be
    /// taken back.
    ///
    /// - Parameters:
    ///   - verbose: Whether `--verbose` was given.
    ///   - quiet: Whether `--quiet` was given.
    init(verbose: Bool, quiet: Bool) {
        switch (quiet, verbose) {
        case (true, _): self = .quiet
        case (false, true): self = .verbose
        case (false, false): self = .normal
        }
    }

    /// Whether the run draws the model resolution progress on stderr.
    ///
    /// `--quiet` turns the download bar off, in a terminal too, which is
    /// the second half of the §5.7 row. The download-progress card reads
    /// this beside `isatty(STDERR_FILENO) == 1` and hands the pair to
    /// ``TerminalRenderer/init(destination:isTerminal:)``.
    var drawsProgress: Bool {
        switch self {
        case .quiet: false
        case .normal, .verbose: true
        }
    }

    /// Whether the run writes one line for each session event.
    var writesEventLines: Bool {
        switch self {
        case .quiet, .normal: false
        case .verbose: true
        }
    }
}

/// The session events of one `run` turn, one line each on stderr
/// (cli-plan.md §5.7).
///
/// **The projection.** The writer reads the same `SessionUpdate` stream
/// the turn already consumes for the answer text, and writes one line for
/// each of the three events §5.7 names: a tool call, a plan update, and
/// the stop reason of the turn. Every other update carries no line. The
/// agent message chunks in particular carry none: they are the answer,
/// and the answer belongs to stdout.
///
/// **The grammar.** Each line opens with a kind word, then the fields of
/// that kind in a fixed order, and every free text stands last, so a tool
/// name that holds a space cannot break a parse:
///
///     tool <toolCallId> <status> <name>
///     plan <completed>/<total> <the task being worked on>
///     stop <stop reason>
///
/// The status words and the stop reason are the wire words, so a line
/// says what the protocol said. ``absentField`` stands where an event
/// carried no value for a field.
///
/// **The tool name rides along.** The agent names a tool on the creation
/// update alone; each later update of that call carries a status and no
/// title. The writer remembers the name by id, so every line of one call
/// names its tool.
///
/// **No ANSI escape, ever.** A `--verbose` run is something a person
/// greps, in a pipe and in a terminal alike, and a control character in a
/// log file is noise. The download bar is where the drawing lives, and
/// ``TerminalRenderer`` owns it.
///
/// **The destination is an argument.** A production call site gives
/// `FileHandle.standardError`. A test gives the write end of a pipe. The
/// writer never touches file descriptor 1.
struct EventLineWriter: Sendable {
    // MARK: - The grammar

    /// The first word of a tool call line.
    static let toolLineKind = "tool"

    /// The first word of a plan line.
    static let planLineKind = "plan"

    /// The first word of the stop line.
    static let stopLineKind = "stop"

    /// What stands where an event carried no value for a field.
    static let absentField = "-"

    /// The separator between two fields of a line.
    private static let fieldSeparator = " "

    // MARK: - Stored properties

    /// The handle every line goes to.
    let destination: FileHandle

    /// How much this writer writes.
    let verbosity: EventVerbosity

    /// The name of each tool call seen so far, by id.
    private var toolNames: [ToolCallId: String] = [:]

    // MARK: - Construction

    /// A writer that writes nothing: the null device, at the quiet
    /// verbosity.
    ///
    /// This is the default of a caller that says nothing about the event
    /// lines, so no suite writes to the process stderr by accident.
    static let silent = EventLineWriter(destination: .nullDevice, verbosity: .quiet)

    /// Creates a writer over one destination.
    ///
    /// - Parameters:
    ///   - destination: The handle each line goes to.
    ///   - verbosity: How much the writer writes.
    init(destination: FileHandle, verbosity: EventVerbosity) {
        self.destination = destination
        self.verbosity = verbosity
    }

    // MARK: - Writing

    /// Writes the line of one session update, when the update has one and
    /// the verbosity asks for it.
    ///
    /// - Parameter update: The update the turn received.
    mutating func receive(_ update: SessionUpdate) {
        guard verbosity.writesEventLines else { return }
        guard let line = line(for: update) else { return }
        write(line)
    }

    /// The line of one session update, or `nil` when the update is not
    /// one of the three events §5.7 names.
    ///
    /// The switch carries a `default` arm on purpose. The wire union
    /// holds seventeen cases and its own `unknown` case for a variant
    /// this revision does not list, so exhaustiveness buys no safety
    /// here: every update that is not a tool call, a plan update or the
    /// end of the turn carries no line, and a later wire case must carry
    /// none either until a card says otherwise.
    ///
    /// - Parameter update: The update the turn received.
    /// - Returns: The line, or `nil`.
    private mutating func line(for update: SessionUpdate) -> String? {
        switch update {
        case .toolCallUpdate(let call):
            return toolLine(for: call)
        case .planUpdate(let plan):
            return Self.planLine(for: plan)
        case .stateUpdate(.idle(let idle)):
            return Self.stopLine(for: idle)
        default:
            return nil
        }
    }

    /// The line of one tool call update, and the name it teaches the
    /// writer.
    ///
    /// - Parameter call: The tool call update.
    /// - Returns: The line.
    private mutating func toolLine(for call: ToolCallUpdate) -> String {
        if case .value(let title) = call.title {
            toolNames[call.toolCallId] = title
        }
        return Self.line(
            of: Self.toolLineKind,
            fields: [
                call.toolCallId.rawValue,
                Self.word(of: call.status) { $0.wireValue },
                toolNames[call.toolCallId] ?? Self.absentField,
            ])
    }

    /// The line of one plan update: how many entries are complete, how
    /// many there are, and the task the plan is working on.
    ///
    /// A variant this revision does not list carries no entries, so it
    /// reports the counts the writer can read, which are zero.
    ///
    /// - Parameter update: The plan update.
    /// - Returns: The line.
    private static func planLine(for update: PlanUpdate) -> String {
        let entries = self.entries(of: update.plan)
        let completed = entries.count { $0.status == .completed }
        let current = entries.first { $0.status == .inProgress }?.content ?? absentField
        return line(of: planLineKind, fields: ["\(completed)/\(entries.count)", current])
    }

    /// The line of the idle state update that ends the turn.
    ///
    /// - Parameter idle: The idle state update.
    /// - Returns: The line.
    private static func stopLine(for idle: IdleStateUpdate) -> String {
        line(of: stopLineKind, fields: [idle.stopReason?.wireValue ?? absentField])
    }

    /// The entries of a plan update, and none for a variant this revision
    /// does not list.
    ///
    /// - Parameter content: The plan content of the update.
    /// - Returns: The entries.
    private static func entries(of content: PlanUpdateContent) -> [PlanEntry] {
        guard case .items(let items) = content else { return [] }
        return items.entries
    }

    /// The word one patch field contributes to a line.
    ///
    /// - Parameters:
    ///   - field: The field of the update.
    ///   - wireValue: The wire spelling of a value the field carried.
    /// - Returns: The wire spelling, or ``absentField`` when the event
    ///   omitted the field or cleared it.
    private static func word<Value>(
        of field: PatchField<Value>, _ wireValue: (Value) -> String
    ) -> String {
        guard case .value(let value) = field else { return absentField }
        return wireValue(value)
    }

    /// One line: the kind word, then the fields, separated by a space.
    ///
    /// - Parameters:
    ///   - kind: The first word of the line.
    ///   - fields: The fields, in line order.
    /// - Returns: The line, with no trailing newline.
    private static func line(of kind: String, fields: [String]) -> String {
        ([kind] + fields).joined(separator: fieldSeparator)
    }

    /// Writes one line and its newline to ``destination``.
    ///
    /// A write that fails is dropped. An event line is not the answer: a
    /// run must not fail because a log line could not reach a closed
    /// pipe.
    ///
    /// - Parameter line: The line to write, with no trailing newline.
    private func write(_ line: String) {
        try? destination.write(contentsOf: Data((line + "\n").utf8))
    }
}
