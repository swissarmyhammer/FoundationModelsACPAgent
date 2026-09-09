import ArgumentParser
import FoundationModelsACP
import FoundationModelsExtras

/// The exit code of `acp-agent` (cli-plan.md §5.8).
///
/// "Nonzero" is not enough for a script, so the whole table stands here
/// and every exit path of the binary reads it:
///
/// | Code | Meaning |
/// |---|---|
/// | 0 | `end_turn`, or a report that ran |
/// | 1 | An error: configuration, spawn, protocol, or I/O. `doctor` found an error. |
/// | 2 | A usage error |
/// | 3 | `refusal` |
/// | 4 | `cancelled` |
/// | 5 | `doctor` found warnings, and no error |
///
/// **There is no 124 row.** cli-plan.md §5.8 lists that `timeout(1)`
/// code for both binaries, but §5.4 gives `run` no `--timeout`, so no
/// code path of this package can produce it. 124 stays in the client
/// CLI's table, where `--timeout` exists.
///
/// The reason of a nonzero exit goes to stderr and never to stdout:
/// stdout carries the answer bytes of the turn, and nothing else (§5.6).
enum AgentExitCode: Int32, CaseIterable, Sendable {
    /// The turn ended on `end_turn`, or a reporting subcommand ran.
    case success = 0

    /// An error: configuration, spawn, protocol, or I/O. `doctor` found
    /// an error.
    case error = 1

    /// A usage error. ArgumentParser's own `validationFailure` is
    /// `EX_USAGE`, which is not the code a script tests for, so
    /// ``AcpAgentCommand/exitOutcome(for:)`` maps it here.
    case usage = 2

    /// The turn ended on `refusal`.
    case refusal = 3

    /// The turn ended on `cancelled`, which is what a `Ctrl-C` gives
    /// (§5.9).
    case cancelled = 4

    /// `doctor` found warnings, and no error. The code is 5 and not 2
    /// because the Rust doctor's 2 for errors would collide with the
    /// usage error above; see `doctor-plan.md` §5.
    case doctorWarnings = 5

    /// The error a subcommand throws so the process ends with this code.
    ///
    /// ArgumentParser renders a thrown `ExitCode` with an empty message,
    /// so nothing is written to either stream: the code alone carries
    /// the outcome, and whatever the subcommand already said stands.
    var parserError: ExitCode {
        ExitCode(rawValue)
    }

    /// The exit code of a turn that ended on `stopReason`.
    ///
    /// **The switch is total, and it declares no `default`.** A
    /// `default` arm would answer every case the wire gains later, so a
    /// new stop reason would exit 0 without a word. With no `default`
    /// the compiler refuses this file — "switch must be exhaustive" —
    /// and the build fails until somebody names the code of the new
    /// reason. That is why the mapping is a switch and not a lookup: a
    /// lookup compiles clean and answers nothing at run time.
    ///
    /// - Parameter stopReason: The stop reason the turn ended on.
    init(stopReason: StopReason) {
        self = switch stopReason {
        case .endTurn: .success
        case .refusal: .refusal
        case .cancelled: .cancelled
        case .maxTokens: .error
        case .maxTurnRequests: .error
        case .unknown: .error
        }
    }

    /// The exit code of a finished `doctor` run (§5.12).
    ///
    /// **The switch is total, and it declares no `default`.** The three
    /// codes are one mapping of the three health statuses, so a status
    /// Extras gains later stops the build here until somebody names its
    /// code.
    ///
    /// The codes match `DoctorReport.exitCode`, which states the same
    /// three numbers in Extras. This table is where every exit path of
    /// this binary reads them from, and ``DoctorCommandTests`` holds the
    /// two side by side so they cannot drift.
    ///
    /// - Parameter report: The report the doctor run built.
    init(doctor report: DoctorReport) {
        self = switch report.worstStatus {
        case .ok: .success
        case .error: .error
        case .warning: .doctorWarnings
        }
    }

    /// The exit code of a finished `run` turn.
    ///
    /// A turn with no stop reason exits ``error``: the wire ended before
    /// an idle update arrived, so the turn has no outcome to report, and
    /// a script must not read that as a finished answer.
    ///
    /// - Parameter result: The finished turn.
    init(turn result: RunTurnResult) {
        guard let stopReason = result.stopReason else {
            self = .error
            return
        }
        self.init(stopReason: stopReason)
    }
}
