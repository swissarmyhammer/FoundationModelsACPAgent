import Foundation
import Synchronization

// MARK: - The mechanical graders (plan.md §20.3)
//
// The evaluators never trust the transcript's claims. `PytestGreen`
// re-runs pytest in the workspace venv and reads the exit code.
// `CLIRuns` re-runs the built CLI against the sample's fixed input and
// compares the bytes it printed. `FilesPresent` stats the disk.
// `ToolTraffic` reads the recorded transcript AND the wire evidence,
// and passes only when the two readings agree. The ungated
// `EvaluatorHonestyTests` holds the first two against a fabricated
// transcript that claims success over a workspace that fails: the
// graders take no transcript text at all, so a lying transcript cannot
// move them.

/// One finished subprocess of a grader: the exit code and the captured
/// streams.
struct PythonCLIProcessResult {
    /// The exit code, or `nil` when the process could not launch.
    let exitCode: Int32?

    /// The captured standard output, decoded as UTF-8.
    let standardOutput: String

    /// The captured standard error, decoded as UTF-8.
    let standardError: String

    /// Whether the watchdog killed the process at the timeout.
    let timedOut: Bool
}

/// A byte sink one pipe drains into, guarded for the reader against
/// the readability handler's appends.
private final class PipeByteCollector: Sendable {
    /// The collected bytes, behind the lock.
    private let guardedBytes = Mutex(Data())

    /// Appends one chunk.
    ///
    /// - Parameter chunk: The bytes to append.
    func append(_ chunk: Data) {
        guardedBytes.withLock { $0.append(chunk) }
    }

    /// The collected bytes, decoded as UTF-8.
    var text: String {
        String(decoding: guardedBytes.withLock { $0 }, as: UTF8.self)
    }
}

/// The four mechanical graders and the subprocess runner they share.
enum PythonCLIGraders {
    /// The directory name of the project-local venv every sample must
    /// create inside its workspace.
    static let venvDirectoryName = ".venv"

    /// The workspace-relative path of the venv's python interpreter —
    /// the one interpreter every re-run uses, so no system Python is
    /// touched.
    static let venvPythonPath = venvDirectoryName + "/bin/python"

    /// How long one grader subprocess may run before the watchdog
    /// kills it. Generous: a cold pytest start on a laptop is seconds,
    /// not minutes.
    static let processTimeoutSeconds: Double = 120

    /// The pause between two looks at a running process.
    private static let processPollSeconds: Double = 0.05

    /// The grace the watchdog gives a terminated process before the
    /// hard kill.
    private static let terminationGraceSeconds: Double = 2

    /// The largest stream tail a failure rationale carries, so one
    /// noisy subprocess cannot flood a report.
    private static let rationaleEvidenceLimit = 400

    // MARK: - PytestGreen

    /// Re-runs pytest in the workspace venv and passes on exit 0.
    ///
    /// The verdict is a function of the filesystem and the exit code
    /// alone. A missing venv fails with the reason; no transcript text
    /// is read.
    ///
    /// - Parameter workspace: The sample's workspace.
    /// - Returns: The verdict, with the exit code as evidence.
    static func pytestGreen(workspace: URL) async -> PythonCLIGradedVerdict {
        guard let python = venvPython(in: workspace) else {
            return PythonCLIGradedVerdict(
                passed: false,
                rationale: "no venv interpreter at \(venvPythonPath)")
        }
        let result = await runProcess(
            executable: python, arguments: ["-m", "pytest", "-q"], workingDirectory: workspace)
        guard result.exitCode == 0, !result.timedOut else {
            return PythonCLIGradedVerdict(
                passed: false,
                rationale: processFailureRationale(of: result, step: "pytest"))
        }
        return PythonCLIGradedVerdict(passed: true, rationale: "pytest exited 0")
    }

    // MARK: - CLIRuns

    /// Re-runs the built CLI against the sample's fixed input and
    /// passes when it exits 0 and prints the fixed output.
    ///
    /// The comparison trims trailing whitespace on both sides, so a
    /// final newline does not decide the verdict. The verdict is a
    /// function of the filesystem, the exit code, and the printed
    /// bytes alone.
    ///
    /// - Parameters:
    ///   - workspace: The sample's workspace.
    ///   - moduleName: The module the CLI runs as, `python -m <name>`.
    ///   - arguments: The fixed input arguments.
    ///   - expectedOutput: The fixed output the run must print.
    /// - Returns: The verdict, with the printed text as evidence.
    static func cliRuns(
        workspace: URL, moduleName: String, arguments: [String], expectedOutput: String
    ) async -> PythonCLIGradedVerdict {
        guard let python = venvPython(in: workspace) else {
            return PythonCLIGradedVerdict(
                passed: false,
                rationale: "no venv interpreter at \(venvPythonPath)")
        }
        let result = await runProcess(
            executable: python,
            arguments: ["-m", moduleName] + arguments,
            workingDirectory: workspace)
        guard result.exitCode == 0, !result.timedOut else {
            return PythonCLIGradedVerdict(
                passed: false,
                rationale: processFailureRationale(of: result, step: "the CLI"))
        }
        let printed = trimmedTrailingWhitespace(of: result.standardOutput)
        let expected = trimmedTrailingWhitespace(of: expectedOutput)
        guard printed == expected else {
            return PythonCLIGradedVerdict(
                passed: false,
                rationale: "the CLI printed \(quoted(printed)), expected \(quoted(expected))")
        }
        return PythonCLIGradedVerdict(
            passed: true, rationale: "the CLI exited 0 and printed \(quoted(expected))")
    }

    // MARK: - FilesPresent

    /// Checks that every required file is on disk in the workspace.
    ///
    /// - Parameters:
    ///   - workspace: The sample's workspace.
    ///   - requiredFiles: The workspace-relative files to check.
    /// - Returns: The verdict, naming each missing file.
    static func filesPresent(
        workspace: URL, requiredFiles: [String]
    ) -> PythonCLIGradedVerdict {
        let missing = requiredFiles.filter { relativePath in
            !FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(relativePath).path)
        }
        guard missing.isEmpty else {
            return PythonCLIGradedVerdict(
                passed: false, rationale: "missing files: \(missing.joined(separator: ", "))")
        }
        return PythonCLIGradedVerdict(
            passed: true, rationale: "all \(requiredFiles.count) required files are on disk")
    }

    // MARK: - ToolTraffic

    /// Checks that the transcript AND the wire both carry real code-mode
    /// tool traffic (the 2026-08-31 card correction).
    ///
    /// The model calls `runCode`, and the snippet calls `tools.files.*`
    /// and `tools.shell.execute`, so the check matches those paths and
    /// never a top-level tool named `files` or `shell`. A sample passes
    /// only when both readings agree: traffic the transcript holds but
    /// the wire never carried is a projection defect, and the eval must
    /// catch it.
    ///
    /// - Parameter evidence: The two readings, derived from the recorded
    ///   transcript and the wire by
    ///   `PythonCLISubject.toolTrafficEvidence(of:)`.
    /// - Returns: The verdict, stating every reading.
    static func toolTraffic(
        evidence: PythonCLIToolTrafficEvidence
    ) -> PythonCLIGradedVerdict {
        let snippets = evidence.transcriptRunCodeSnippets.joined(separator: "\n")
        let readings = [
            ("the transcript holds a runCode snippet calling tools.files.*",
             snippets.contains(PythonCLIToolTrafficEvidence.filesVerbPathPrefix)),
            ("the transcript holds a runCode snippet calling tools.shell.execute",
             snippets.contains(PythonCLIToolTrafficEvidence.shellExecuteVerbPath)),
            ("the transcript holds the shell run's completed report",
             evidence.transcriptCompletedShellEventCount > 0),
            ("the wire holds a completed runCode tool call",
             evidence.completedRunCodeCallCount > 0),
            ("the wire holds the shell steps' streamed output",
             evidence.shellStreamNotificationCount > 0),
        ]
        let failed = readings.filter { !$0.1 }.map(\.0)
        guard failed.isEmpty else {
            return PythonCLIGradedVerdict(
                passed: false,
                rationale: "missing readings: \(failed.joined(separator: "; "))")
        }
        return PythonCLIGradedVerdict(
            passed: true,
            rationale: "all \(readings.count) transcript and wire readings agree")
    }

    // MARK: - The subprocess runner

    /// Runs one grader subprocess to completion under the watchdog,
    /// off the cooperative pool.
    ///
    /// - Parameters:
    ///   - executable: The program to run.
    ///   - arguments: Its arguments.
    ///   - workingDirectory: Its working directory.
    /// - Returns: The exit code and the captured streams.
    static func runProcess(
        executable: URL, arguments: [String], workingDirectory: URL
    ) async -> PythonCLIProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: runProcessBlocking(
                        executable: executable,
                        arguments: arguments,
                        workingDirectory: workingDirectory))
            }
        }
    }

    /// The blocking body of ``runProcess(executable:arguments:workingDirectory:)``:
    /// launches, drains both pipes through readability handlers so a
    /// full pipe never deadlocks the child, polls to the deadline, and
    /// kills a run that outlives it.
    private static func runProcessBlocking(
        executable: URL, arguments: [String], workingDirectory: URL
    ) -> PythonCLIProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        let standardOutput = attachCollector(to: process, keyPath: \.standardOutput)
        let standardError = attachCollector(to: process, keyPath: \.standardError)
        do {
            try process.run()
        } catch {
            return PythonCLIProcessResult(
                exitCode: nil,
                standardOutput: "",
                standardError: "launch failed: \(error)",
                timedOut: false)
        }
        let deadline = Date().addingTimeInterval(processTimeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: processPollSeconds)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let grace = Date().addingTimeInterval(terminationGraceSeconds)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: processPollSeconds)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        return PythonCLIProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: standardOutput.text,
            standardError: standardError.text,
            timedOut: timedOut)
    }

    /// Wires one collector-backed pipe into `process` at `keyPath`.
    ///
    /// The readability handler drains the pipe as the child writes, so
    /// output larger than the pipe buffer never blocks the child. The
    /// final chunk arrives with the empty read that clears the handler.
    private static func attachCollector(
        to process: Process, keyPath: ReferenceWritableKeyPath<Process, Any?>
    ) -> PipeByteCollector {
        let collector = PipeByteCollector()
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(chunk)
            }
        }
        process[keyPath: keyPath] = pipe
        return collector
    }

    // MARK: - The rationale helpers

    /// The venv interpreter of `workspace`, or `nil` when it is not on
    /// disk.
    private static func venvPython(in workspace: URL) -> URL? {
        let python = workspace.appendingPathComponent(venvPythonPath)
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            return nil
        }
        return python
    }

    /// The failure sentence of one subprocess result: the exit code or
    /// the timeout, and the tail of the streams as evidence.
    private static func processFailureRationale(
        of result: PythonCLIProcessResult, step: String
    ) -> String {
        let ending =
            result.timedOut
            ? "timed out after \(Int(processTimeoutSeconds)) s"
            : "exited \(result.exitCode.map(String.init) ?? "without launching")"
        let evidence = trimmedTrailingWhitespace(
            of: result.standardOutput + "\n" + result.standardError)
        return "\(step) \(ending): \(evidence.suffix(rationaleEvidenceLimit))"
    }

    /// `text` without trailing whitespace and newlines.
    private static func trimmedTrailingWhitespace(of text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
    }

    /// `text` wrapped in double quotes for a rationale sentence.
    private static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }
}

/// The two tool-traffic readings — the recorded transcript and the
/// wire — reduced to the counts and snippets the grader compares.
struct PythonCLIToolTrafficEvidence: Sendable, Equatable {
    /// The verb-path prefix every files call in a snippet starts with.
    static let filesVerbPathPrefix = "tools.files."

    /// The verb path of a shell run in a snippet.
    static let shellExecuteVerbPath = "tools.shell.execute"

    /// The `code` arguments of the recorded `runCode` tool calls, read
    /// from the transcript's `.toolCalls` entries.
    let transcriptRunCodeSnippets: [String]

    /// How many recorded events carry the shell run's completed
    /// report — the `"execute shell"` journal op with its completion
    /// state, in a recorded `.toolOutput` segment.
    let transcriptCompletedShellEventCount: Int

    /// How many completed `runCode` tool calls the client container
    /// accumulated (`ACPSessionState.toolCalls`).
    let completedRunCodeCallCount: Int

    /// How many notifications carried the shell steps' streamed output:
    /// `tool_call_content_chunk`, or the landed terminal vocabulary
    /// (`terminal_output_chunk` / `terminal_update`, plan.md §11.8).
    let shellStreamNotificationCount: Int
}
