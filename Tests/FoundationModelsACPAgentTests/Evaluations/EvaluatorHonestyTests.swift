import Foundation
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Evaluator honesty (plan.md §20.3, the acceptance criterion)
//
// The graders must grade from the filesystem and the exit codes, never
// from transcript text. Each failing case here plants a fabricated
// transcript that CLAIMS success in the workspace, makes the workspace
// itself fail deliberately, and asserts the grader still fails. The
// graders take no transcript parameter at all, so the lie has no way
// in — and these cases prove the verdict tracks the disk, not the
// claim. The passing cases prove each grader can pass, so a grader
// that fails unconditionally cannot hide here.

/// The honesty fixtures: a workspace with a planted venv interpreter
/// and planted Python modules, built with no network and no package
/// install.
private enum HonestyFixtures {
    /// The fabricated transcript text: an agent's dishonest claim of
    /// success. Planted in every failing workspace to prove it cannot
    /// move a grader.
    static let lyingTranscript = """
        {"kind":"toolOutput","text":"pytest -q: 24 passed in 0.31s, exit 0"}
        {"kind":"response","text":"All tests pass and the CLI prints the expected output."}
        """

    /// The file the fabricated transcript is planted at.
    static let lyingTranscriptFileName = "transcript.jsonl"

    /// The `python3` shim every macOS carries. It dispatches on its
    /// own invocation name, so a symlink named `python` cannot point
    /// at it — ``realPython3Path()`` resolves through it instead.
    private static let python3ShimPath = "/usr/bin/python3"

    /// The real `python3` interpreter behind the `/usr/bin/python3`
    /// shim, asked from the interpreter itself. The shim dispatches on
    /// `argv[0]`, so a symlink named `python` must target the real
    /// binary, never the shim.
    ///
    /// - Returns: The interpreter's absolute path.
    /// - Throws: ``HonestyFixtureError/python3Unavailable(_:)`` when
    ///   the shim cannot answer.
    static func realPython3Path() async throws -> String {
        let result = await PythonCLIGraders.runProcess(
            executable: URL(fileURLWithPath: python3ShimPath),
            arguments: ["-c", "import sys; print(sys.executable)"],
            workingDirectory: FileManager.default.temporaryDirectory)
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !path.isEmpty else {
            throw HonestyFixtureError.python3Unavailable(result.standardError)
        }
        return path
    }

    /// Makes a workspace with a planted `.venv/bin/python` that links
    /// to the real system `python3` interpreter, so a grader re-run
    /// really executes — with no venv creation and no network.
    ///
    /// - Parameter label: The directory label of the calling test.
    /// - Returns: The workspace.
    /// - Throws: The link error, or
    ///   ``HonestyFixtureError/python3Unavailable(_:)``.
    static func makeWorkspaceWithVenv(label: String) async throws -> URL {
        let workspace = makeResolvedDirectory(label: label)
        let binDirectory =
            workspace
            .appendingPathComponent(PythonCLIGraders.venvDirectoryName, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: binDirectory.appendingPathComponent("python"),
            withDestinationURL: URL(fileURLWithPath: try await realPython3Path()))
        return workspace
    }

    /// Plants a Python module in the workspace root, where `-m` finds
    /// it first.
    ///
    /// - Parameters:
    ///   - name: The module name, without the `.py` suffix.
    ///   - body: The module body.
    ///   - workspace: The workspace to plant into.
    /// - Throws: The write error.
    static func plantModule(named name: String, body: String, in workspace: URL) throws {
        try body.write(
            to: workspace.appendingPathComponent("\(name).py"),
            atomically: true, encoding: .utf8)
    }

    /// Plants the fabricated success-claiming transcript in the
    /// workspace.
    ///
    /// - Parameter workspace: The workspace to plant into.
    /// - Throws: The write error.
    static func plantLyingTranscript(in workspace: URL) throws {
        try lyingTranscript.write(
            to: workspace.appendingPathComponent(lyingTranscriptFileName),
            atomically: true, encoding: .utf8)
    }
}

/// What the honesty fixtures refused.
private enum HonestyFixtureError: Error {
    /// The `python3` shim answered with a failure, so no real
    /// interpreter is available to plant.
    case python3Unavailable(String)
}

/// The graders' honesty: the verdicts track the filesystem and the
/// exit codes, and a fabricated transcript that claims success cannot
/// move them.
@Suite struct EvaluatorHonestyTests {
    // MARK: - PytestGreen

    /// A workspace whose pytest run exits nonzero grades FAIL, with
    /// the fabricated success-claiming transcript planted right beside
    /// it. The verdict reads the exit code; the claim has no way in.
    @Test(.timeLimit(.minutes(1)))
    func pytestGreenFailsAFailingWorkspaceDespiteALyingTranscript() async throws {
        let workspace = try await HonestyFixtures.makeWorkspaceWithVenv(
            label: "EvaluatorHonesty-pytest-red")
        try HonestyFixtures.plantModule(
            named: "pytest", body: "raise SystemExit(1)\n", in: workspace)
        try HonestyFixtures.plantLyingTranscript(in: workspace)

        let verdict = await PythonCLIGraders.pytestGreen(workspace: workspace)

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("exited 1"))
    }

    /// A workspace whose pytest run exits 0 grades PASS, so the FAIL
    /// above is a judgment and not a constant.
    @Test(.timeLimit(.minutes(1)))
    func pytestGreenPassesAWorkspaceWhosePytestExitsZero() async throws {
        let workspace = try await HonestyFixtures.makeWorkspaceWithVenv(
            label: "EvaluatorHonesty-pytest-green")
        try HonestyFixtures.plantModule(
            named: "pytest", body: "raise SystemExit(0)\n", in: workspace)

        let verdict = await PythonCLIGraders.pytestGreen(workspace: workspace)

        #expect(verdict.passed)
    }

    /// A workspace with no venv grades FAIL and names the missing
    /// interpreter: nothing to run is a failure, never a free pass.
    @Test(.timeLimit(.minutes(1)))
    func pytestGreenFailsAWorkspaceWithNoVenv() async {
        let workspace = makeResolvedDirectory(label: "EvaluatorHonesty-no-venv")

        let verdict = await PythonCLIGraders.pytestGreen(workspace: workspace)

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains(PythonCLIGraders.venvPythonPath))
    }

    // MARK: - CLIRuns

    /// A CLI that prints the wrong output grades FAIL, with the
    /// fabricated success-claiming transcript planted beside it. The
    /// verdict compares the bytes the re-run really printed.
    @Test(.timeLimit(.minutes(1)))
    func cliRunsFailsAWrongOutputDespiteALyingTranscript() async throws {
        let workspace = try await HonestyFixtures.makeWorkspaceWithVenv(
            label: "EvaluatorHonesty-cli-wrong")
        try HonestyFixtures.plantModule(
            named: "greet_cli", body: "print(\"Goodbye\")\n", in: workspace)
        try HonestyFixtures.plantLyingTranscript(in: workspace)

        let verdict = await PythonCLIGraders.cliRuns(
            workspace: workspace,
            moduleName: "greet_cli",
            arguments: ["--name", "World"],
            expectedOutput: "Hello, World!")

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("Goodbye"))
    }

    /// A CLI whose run exits nonzero grades FAIL even when the
    /// fabricated transcript claims success.
    @Test(.timeLimit(.minutes(1)))
    func cliRunsFailsANonzeroExitDespiteALyingTranscript() async throws {
        let workspace = try await HonestyFixtures.makeWorkspaceWithVenv(
            label: "EvaluatorHonesty-cli-exit")
        try HonestyFixtures.plantModule(
            named: "greet_cli",
            body: "print(\"Hello, World!\")\nraise SystemExit(3)\n",
            in: workspace)
        try HonestyFixtures.plantLyingTranscript(in: workspace)

        let verdict = await PythonCLIGraders.cliRuns(
            workspace: workspace,
            moduleName: "greet_cli",
            arguments: [],
            expectedOutput: "Hello, World!")

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("exited 3"))
    }

    /// A CLI that prints the expected output grades PASS, so the FAIL
    /// cases above are judgments and not constants.
    @Test(.timeLimit(.minutes(1)))
    func cliRunsPassesTheExpectedOutput() async throws {
        let workspace = try await HonestyFixtures.makeWorkspaceWithVenv(
            label: "EvaluatorHonesty-cli-green")
        try HonestyFixtures.plantModule(
            named: "greet_cli", body: "print(\"Hello, World!\")\n", in: workspace)

        let verdict = await PythonCLIGraders.cliRuns(
            workspace: workspace,
            moduleName: "greet_cli",
            arguments: ["--name", "World"],
            expectedOutput: "Hello, World!")

        #expect(verdict.passed)
    }

    // MARK: - FilesPresent

    /// A missing required file grades FAIL and is named in the
    /// rationale; a complete set grades PASS.
    @Test(.timeLimit(.minutes(1)))
    func filesPresentTracksTheDisk() throws {
        let workspace = makeResolvedDirectory(label: "EvaluatorHonesty-files")
        try HonestyFixtures.plantModule(named: "greet_cli", body: "\n", in: workspace)

        let missing = PythonCLIGraders.filesPresent(
            workspace: workspace, requiredFiles: ["greet_cli.py", "pyproject.toml"])
        let present = PythonCLIGraders.filesPresent(
            workspace: workspace, requiredFiles: ["greet_cli.py"])

        #expect(!missing.passed)
        #expect(missing.rationale.contains("pyproject.toml"))
        #expect(present.passed)
    }

    // MARK: - ToolTraffic

    /// Transcript-side traffic that never reached the wire grades
    /// FAIL: a snippet full of verb paths cannot pass while the wire
    /// counts are zero — that disagreement is a projection defect the
    /// eval must catch.
    @Test(.timeLimit(.minutes(1)))
    func toolTrafficFailsWhenTheWireNeverCarriedTheTraffic() {
        let evidence = PythonCLIToolTrafficEvidence(
            transcriptRunCodeSnippets: [
                "runCode: await tools.files.write(...); await tools.shell.execute(...)"
            ],
            transcriptCompletedShellEventCount: 1,
            completedRunCodeCallCount: 0,
            shellStreamNotificationCount: 0)

        let verdict = PythonCLIGraders.toolTraffic(evidence: evidence)

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("wire"))
    }

    /// Wire-side traffic with an empty transcript grades FAIL: the two
    /// readings must agree.
    @Test(.timeLimit(.minutes(1)))
    func toolTrafficFailsWhenTheTranscriptHoldsNoTraffic() {
        let evidence = PythonCLIToolTrafficEvidence(
            transcriptRunCodeSnippets: [],
            transcriptCompletedShellEventCount: 0,
            completedRunCodeCallCount: 1,
            shellStreamNotificationCount: 1)

        let verdict = PythonCLIGraders.toolTraffic(evidence: evidence)

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("transcript"))
    }

    /// Agreeing readings grade PASS, so the FAIL cases above are
    /// judgments and not constants.
    @Test(.timeLimit(.minutes(1)))
    func toolTrafficPassesWhenBothReadingsAgree() {
        let evidence = PythonCLIToolTrafficEvidence(
            transcriptRunCodeSnippets: [
                "runCode: await tools.files.write(...); await tools.shell.execute(...)"
            ],
            transcriptCompletedShellEventCount: 1,
            completedRunCodeCallCount: 1,
            shellStreamNotificationCount: 1)

        let verdict = PythonCLIGraders.toolTraffic(evidence: evidence)

        #expect(verdict.passed)
    }
}
