import Foundation
import Testing

// MARK: - The one launch-and-capture of the support code
//
// `BuiltExecutableRun`, `ProcessCensus` and `TemporaryKeychain` each run a
// child to its end through `CapturedProcessRun`. These cases run `/bin/sh`
// with a fixed script, so each one names the bytes and the status the run
// must give back.

/// `CapturedProcessRun` gives back the exit status and the output of a child.
struct CapturedProcessRunTests {
    /// The absolute path of `sh(1)`.
    private static let shellPath = "/bin/sh"

    /// The exit status the script of each case ends with. It is neither 0
    /// nor 1, so a run that read the wrong status cannot match it by chance.
    private static let scriptExitCode: Int32 = 3

    /// The text the script writes to its stdout.
    private static let outputText = "to-stdout"

    /// The text the script writes to its stderr, after the stdout text.
    private static let errorText = "to-stderr"

    /// More bytes than a pipe buffer holds, so a run that waited for the exit
    /// before it read would never see the child end.
    private static let overfullByteCount = 1 << 20

    /// The script that writes ``outputText`` to stdout, then ``errorText`` to
    /// stderr, then exits with ``scriptExitCode``.
    private static var twoStreamScript: String {
        "printf '\(outputText)'; printf '\(errorText)' >&2; exit \(scriptExitCode)"
    }

    /// A tool whose stderr is merged gives back both streams in one output,
    /// in the order it wrote them, and its exit status.
    @Test func aToolWithMergedErrorOutputGivesBackBothStreamsAndItsStatus() async throws {
        let run = try await CapturedProcessRun.run(
            toolAt: Self.shellPath, arguments: ["-c", Self.twoStreamScript],
            errorOutput: .mergedIntoOutput)

        #expect(run.exitCode == Self.scriptExitCode)
        #expect(String(decoding: run.standardOutput, as: UTF8.self) == Self.outputText + Self.errorText)
        #expect(run.standardError.isEmpty)
    }

    /// A tool whose stderr is inherited gives back its stdout alone.
    @Test func aToolWithInheritedErrorOutputGivesBackItsStandardOutputAlone() async throws {
        let run = try await CapturedProcessRun.run(
            toolAt: Self.shellPath, arguments: ["-c", Self.twoStreamScript],
            errorOutput: .inherited)

        #expect(run.exitCode == Self.scriptExitCode)
        #expect(String(decoding: run.standardOutput, as: UTF8.self) == Self.outputText)
        #expect(run.standardError.isEmpty)
    }

    /// A tool whose stderr is captured gives back each stream apart, and its
    /// exit status.
    @Test func aToolWithCapturedErrorOutputGivesBackEachStreamApart() async throws {
        let run = try await CapturedProcessRun.run(
            toolAt: Self.shellPath, arguments: ["-c", Self.twoStreamScript],
            errorOutput: .captured)

        #expect(run.exitCode == Self.scriptExitCode)
        #expect(String(decoding: run.standardOutput, as: UTF8.self) == Self.outputText)
        #expect(String(decoding: run.standardError, as: UTF8.self) == Self.errorText)
    }

    /// A process with a pipe for each stream gives back each stream apart.
    @Test func aProcessWithTwoPipesGivesBackEachStreamApart() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.shellPath)
        process.arguments = ["-c", Self.twoStreamScript]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        let run = try await CapturedProcessRun.run(process, standardOutput: output, standardError: error)

        #expect(run.exitCode == Self.scriptExitCode)
        #expect(String(decoding: run.standardOutput, as: UTF8.self) == Self.outputText)
        #expect(String(decoding: run.standardError, as: UTF8.self) == Self.errorText)
    }

    /// A child that writes more than a pipe buffer holds still ends, and the
    /// run gives back every byte.
    @Test func aChildThatOverfillsThePipeBufferEndsWithEveryByteRead() async throws {
        let run = try await CapturedProcessRun.run(
            toolAt: Self.shellPath,
            arguments: ["-c", "head -c \(Self.overfullByteCount) /dev/zero"],
            errorOutput: .inherited)

        #expect(run.exitCode == 0)
        #expect(run.standardOutput.count == Self.overfullByteCount)
    }
}
