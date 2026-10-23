// `ProcessCensus` — which processes this machine is running right now.
//
// Every tier-3 suite that spawns a binary owes one proof: no agent process
// outlives the run. A leaked agent holds gigabytes of model weights, and
// once a run has ended nothing inside this process can see it, so the proof
// reads the live process table.
//
// Three readings stand here, and each one names its subject exactly. That
// matters because the suites of this package run beside each other, and
// each of several of them has an `acp-agent acp` process of its own alive
// at any moment. A reading that counted every agent would report a
// neighbour's healthy child as this run's leak.
//
// - The children OF ONE PARENT answer which agent one live run started.
// - The process GROUP of one live child names the processes whose exit
//   events a test arms (`ArmedProcessExit`) before the run ends.
// - The ORPHANS answer the leak question for a run whose child was never
//   seen. An agent that outlived the run that started it has lost its
//   parent, so the system has given it to `launchd` — process 1. An agent
//   another suite is running at the same moment still has its own live
//   parent, and stands in no reading here.

import Darwin
import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

/// The live processes of this machine, read through `pgrep(1)`.
enum ProcessCensus {
    /// The absolute path of `pgrep(1)`.
    private static let pgrepPath = "/usr/bin/pgrep"

    /// The name `pgrep` is reported under when it fails.
    private static let pgrepName = "pgrep"

    /// The exit status `pgrep` reports when a process matches.
    private static let matchStatus: Int32 = 0

    /// The exit status `pgrep` reports when no process matches.
    private static let noMatchStatus: Int32 = 1

    /// The identifier of `launchd`, which the system gives every orphan to.
    private static let orphanParentIdentifier: pid_t = 1

    /// The identifiers of the processes that match every one of
    /// `arguments`.
    ///
    /// `pgrep` exits 0 when a process matches and 1 when none does. Any other
    /// status means `pgrep` itself failed, with an empty stdout, so it is
    /// thrown: a census that could not read the process table never reports
    /// no process.
    ///
    /// - Parameter arguments: The selection `pgrep` is given. It ands them.
    /// - Returns: The matching identifiers, and none when nothing matches.
    /// - Throws: The run error of `pgrep` (see ``CapturedProcessRun``), or a
    ///   ``CapturedProcessRun/Failure`` with the status and the stderr of
    ///   `pgrep` when it exits with a status other than 0 or 1.
    static func identifiers(selectedBy arguments: [String]) async throws -> [pid_t] {
        let pgrep = try await CapturedProcessRun.run(
            toolAt: pgrepPath, arguments: arguments, errorOutput: .captured)
        switch pgrep.exitCode {
        case matchStatus:
            return matchingIdentifiers(in: pgrep.standardOutput)
        case noMatchStatus:
            return []
        default:
            throw CapturedProcessRun.Failure(
                command: pgrepName, status: pgrep.exitCode,
                output: String(decoding: pgrep.standardError, as: UTF8.self))
        }
    }

    /// The identifiers `pgrep` wrote, one to a line.
    ///
    /// - Parameter output: The stdout of `pgrep`.
    /// - Returns: The identifiers.
    private static func matchingIdentifiers(in output: Data) -> [pid_t] {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The folder macOS keeps `/tmp`, `/var` and `/etc` in. Each of those
    /// three is a link into it.
    private static let privateFolder = "/private"

    /// The characters a POSIX extended regular expression reads as
    /// operators, as `re_format(7)` names them.
    private static let extendedExpressionOperators: Set<Character> = [
        "\\", ".", "[", "]", "(", ")", "*", "+", "?", "{", "}", "|", "^", "$",
    ]

    /// The command line of the built `acp-agent` serving ACP over stdio.
    ///
    /// - Returns: The pattern `pgrep -f` is given.
    /// - Throws: The locator error.
    private static func agentServingACPPattern() throws -> String {
        agentServingACPPattern(
            agentPath: try BuiltProductLocator.executableURL(
                named: TierThreeFixture.agentExecutableName
            ).path)
    }

    /// The command line an `acp-agent` at `agentPath` carries when it serves
    /// ACP over stdio.
    ///
    /// It names the binary's own path beside the `acp` subcommand, so a
    /// parent `acp-agent run …` of the same binary never matches, and only a
    /// spawned wire server does.
    ///
    /// Foundation `Process` removes the `/private` prefix from the path it
    /// starts, so a binary built under `/private/tmp` runs as `/tmp/…`. The
    /// pattern holds the path without that prefix, and `pgrep -f` matches it
    /// anywhere in the command line, thus it finds the child in each of the
    /// two path forms. Each operator character of the path is escaped, so the
    /// path matches as literal text.
    ///
    /// - Parameter agentPath: The absolute path of the `acp-agent` binary.
    /// - Returns: The extended regular expression `pgrep -f` is given.
    static func agentServingACPPattern(agentPath: String) -> String {
        let pathInEachForm =
            agentPath.hasPrefix("\(privateFolder)/")
            ? String(agentPath.dropFirst(privateFolder.count)) : agentPath
        let literalPath = pathInEachForm.map { character in
            extendedExpressionOperators.contains(character) ? "\\\(character)" : String(character)
        }.joined()
        return "\(literalPath) \(TierThreeFixture.acpSubcommand)"
    }

    /// The identifiers of the `acp-agent acp` processes the live process
    /// `parent` started.
    ///
    /// It answers only while `parent` is alive, because a child is reaped
    /// with its parent and reported under no parent afterwards.
    ///
    /// - Parameter parent: The identifier of the run that started them.
    /// - Returns: The identifiers, and none when that parent started none.
    /// - Throws: The locator error, and the error of
    ///   ``identifiers(selectedBy:)`` when `pgrep` cannot be run or fails.
    static func agentsServingACP(startedBy parent: pid_t) async throws -> [pid_t] {
        try await identifiers(selectedBy: ["-P", String(parent), "-f", agentServingACPPattern()])
    }

    /// The identifiers of the `acp-agent acp` processes that outlived the
    /// run that started them.
    ///
    /// - Returns: The identifiers, and none when every run reaped its own
    ///   child.
    /// - Throws: The locator error, and the error of
    ///   ``identifiers(selectedBy:)`` when `pgrep` cannot be run or fails.
    static func orphanedAgentsServingACP() async throws -> [pid_t] {
        try await identifiers(
            selectedBy: [
                "-P", String(orphanParentIdentifier), "-f", agentServingACPPattern(),
            ])
    }

    /// Asserts that no `acp-agent acp` process outlived the run that
    /// started it.
    ///
    /// This is the reap proof every tier-3 suite that spawns an agent
    /// makes, so it stands in one place and the suites cannot drift apart.
    ///
    /// A census that could not read the process table throws, so the proof
    /// fails instead of passing on an empty reading.
    ///
    /// - Parameter sourceLocation: The test line a failure is reported at.
    /// - Throws: The locator error, and the error of
    ///   ``identifiers(selectedBy:)`` when `pgrep` cannot be run or fails.
    static func expectNoAgentOutlivedItsRun(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let orphans = try await orphanedAgentsServingACP()
        #expect(
            orphans.isEmpty,
            "an agent outlived the run that started it: \(orphans)",
            sourceLocation: sourceLocation)
    }
}
