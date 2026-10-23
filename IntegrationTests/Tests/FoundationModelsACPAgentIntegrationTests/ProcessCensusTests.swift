import Darwin
import Foundation
import Testing

// MARK: - The `pgrep -f` pattern of `ProcessCensus`
//
// The census finds a spawned `acp-agent acp` by its command line. Foundation
// `Process` removes the `/private` prefix from the path it starts, so a
// binary built under `/private/tmp/x` runs as `/tmp/x/acp-agent acp`. The
// pattern must find the child in both path forms, and it must still refuse
// the parent `acp-agent run …` of the same binary.
//
// These cases match with `regcomp(3)` and `REG_EXTENDED`, which is the
// engine `pgrep(1)` compiles its pattern with. They spawn no process.

/// The pattern `ProcessCensus` gives `pgrep -f` for an agent serving ACP.
struct ProcessCensusTests {
    /// The binary path under `/private/tmp`, the form SwiftPM states for a
    /// build folder there.
    private static let privateTemporaryAgentPath = "/private/tmp/x/acp-agent"

    /// The parent command line of the same binary, which a census of the
    /// children must never count.
    private static let parentCommandLine = "/tmp/x/acp-agent run --out-of-process prompt"

    /// A binary path whose folder name holds the regular-expression
    /// metacharacter `.`.
    private static let dottedAgentPath = "/Users/a/.build/acp-agent"

    /// A command line that matches ``dottedAgentPath`` only when the `.` is
    /// read as "any character".
    private static let undottedCommandLine = "/Users/a/xbuild/acp-agent acp"

    /// Whether `commandLine` matches `pattern` as `pgrep -f` reads it.
    ///
    /// - Parameters:
    ///   - pattern: The extended regular expression.
    ///   - commandLine: The full command line of a process.
    /// - Returns: `true` when the expression matches anywhere in the line.
    /// - Throws: The `#require` failure when the expression does not compile.
    private static func pgrepMatches(_ pattern: String, commandLine: String) throws -> Bool {
        var expression = regex_t()
        let status = regcomp(&expression, pattern, REG_EXTENDED | REG_NOSUB)
        try #require(status == 0, "the pattern does not compile: \(pattern)")
        defer { regfree(&expression) }
        return regexec(&expression, commandLine, 0, nil, 0) == 0
    }

    /// A pattern made from the `/private/tmp` path finds the child in both
    /// path forms: the form `Process` gives it, and the form SwiftPM states.
    @Test(arguments: ["/tmp/x/acp-agent acp", "/private/tmp/x/acp-agent acp"])
    func aPrivateTemporaryPathFindsTheChildInEachPathForm(commandLine: String) throws {
        let pattern = ProcessCensus.agentServingACPPattern(
            agentPath: Self.privateTemporaryAgentPath)
        let matches = try Self.pgrepMatches(pattern, commandLine: commandLine)
        #expect(matches, "pattern: \(pattern)")
    }

    /// The parent `acp-agent run …` of the same binary does not match, so a
    /// census of the children counts no parent.
    @Test func theParentRunOfTheSameBinaryDoesNotMatch() throws {
        let pattern = ProcessCensus.agentServingACPPattern(
            agentPath: Self.privateTemporaryAgentPath)
        let matches = try Self.pgrepMatches(pattern, commandLine: Self.parentCommandLine)
        #expect(!matches, "pattern: \(pattern)")
    }

    /// A `.` in the path matches only a `.`, so the pattern names one binary
    /// and not every path of the same shape.
    @Test func aDotInThePathMatchesOnlyADot() throws {
        let pattern = ProcessCensus.agentServingACPPattern(agentPath: Self.dottedAgentPath)
        let matches = try Self.pgrepMatches(pattern, commandLine: Self.undottedCommandLine)
        #expect(!matches, "pattern: \(pattern)")
    }
}

// MARK: - The exit status of the `pgrep` a census runs
//
// `pgrep(1)` exits 0 when a process matches and 1 when none does. Any other
// status means `pgrep` itself failed — 2 for a selection it cannot read — and
// its stdout is then empty. A census that read that empty stdout as "no
// process" would let the reap proof pass without reading the process table,
// so a failed `pgrep` must fail the census. These cases run the real `pgrep`.

/// How `ProcessCensus` reads the exit status of `pgrep`.
struct ProcessCensusExitStatusTests {
    /// A `pgrep -f` pattern the regular-expression engine cannot compile.
    private static let uncompilablePattern = "("

    /// The status `pgrep` exits with when it cannot read its selection.
    private static let unreadableSelectionStatus: Int32 = 2

    /// The words `pgrep` writes to its stderr when its pattern does not
    /// compile.
    private static let uncompilablePatternComplaint = "Cannot compile regular expression"

    /// A census whose `pgrep` fails throws, and the error names the status and
    /// what `pgrep` wrote to its stderr, instead of reporting no process.
    @Test func aCensusWhosePgrepFailsThrowsItsStatusAndItsErrorOutput() async throws {
        let error = await #expect(throws: (any Error).self) {
            try await ProcessCensus.identifiers(selectedBy: ["-f", Self.uncompilablePattern])
        }

        let description = String(describing: try #require(error))
        #expect(description.contains("status \(Self.unreadableSelectionStatus)"), "\(description)")
        #expect(description.contains(Self.uncompilablePatternComplaint), "\(description)")
    }

    /// A census that matches no process gives no identifiers and throws
    /// nothing: `pgrep` exits 1 for it, and that is a sound reading.
    @Test func aCensusThatMatchesNoProcessGivesNoIdentifiers() async throws {
        let nobodysCommandLine = UUID().uuidString

        let identifiers = try await ProcessCensus.identifiers(selectedBy: ["-f", nobodysCommandLine])

        #expect(identifiers.isEmpty)
    }
}
