import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

// MARK: - Evaluator honesty (plan.md §20.3, the acceptance criterion)
//
// The graders must grade from the filesystem, from the exit codes, and
// from the counts. They must not grade from a claim. Each failing case
// makes the workspace fail on purpose, or synthesizes evidence whose
// two sides disagree, and asserts that the grader still fails. Each
// passing case shows that the same grader can pass. Thus a grader that
// always fails cannot hide here.
//
// The planted transcript: what it shows, and what it does not show.
// Three cases write a fabricated transcript into the workspace, and
// the transcript claims success. No grader has a transcript parameter.
// Thus no case gives the fabricated text to a grader as an argument,
// and no case here shows a grader that refused a lie handed to it.
// The cases show only this: a fabricated file in the workspace does
// not move the verdict. `PytestGreen` and `CLIRuns` run their
// subprocess in that directory, so the workspace IS an input they
// read. Do not read more into these cases.
//
// Why these tests stay in the nested integration package. The
// ToolTraffic cases open no workspace and load no model, so the root
// unit target could run them. But the root target cannot see this
// package, and `PythonCLIGraders` also holds three graders that spawn
// subprocesses. A move thus needs the whole grader file in the shared
// `FoundationModelsACPAgentTestSupport` library, or one grader taken
// out of the file its own header describes. CI runs this package on
// every push and on every pull request: `.github/workflows/ci.yml`
// gives `integration-package-path: IntegrationTests` to the shared
// workflow. The package split thus already gives these tests an
// ungated run.

/// The honesty fixtures: a workspace with a planted venv interpreter
/// and planted Python modules, built with no network and no package
/// install.
private enum HonestyFixtures {
    /// The fabricated transcript text: an agent's dishonest claim of
    /// success. Written into a failing workspace, where a grader reads
    /// the workspace but never this file.
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

    /// The one recorded `runCode` snippet of a healthy run: it calls
    /// both verb paths ``PythonCLIGraders/toolTraffic(evidence:)``
    /// matches for.
    static let runCodeSnippet =
        "runCode: await tools.files.write(...); await tools.shell.execute(...)"

    /// The tool-traffic evidence of a healthy run, with every reading
    /// in agreement: one `runCode` call on the transcript side and one
    /// on the wire, one completed shell run, and two notifications for
    /// that run.
    ///
    /// Two notifications for one shell run, and not one, because the
    /// wire carries at least one notification per completed run and
    /// usually more. Each case below overrides only the readings it is
    /// about, so what makes a case fail is visible in the call.
    ///
    /// - Parameters:
    ///   - snippets: The recorded `runCode` payloads.
    ///   - transcriptRunCodeCallCount: The `runCode` calls the recorded
    ///     `.toolCalls` entries announced.
    ///   - transcriptCompletedShellEventCount: The recorded events
    ///     carrying a shell run's completed report.
    ///   - projectedRunCodeCallCount: The announced `runCode` calls the
    ///     wire carries.
    ///   - completedRunCodeCallCount: The announced `runCode` calls the
    ///     wire completed.
    ///   - shellStreamNotificationCount: The shell stream
    ///     notifications on the wire.
    /// - Returns: The evidence value.
    static func toolTrafficEvidence(
        snippets: [String] = [runCodeSnippet],
        transcriptRunCodeCallCount: Int = 1,
        transcriptCompletedShellEventCount: Int = 1,
        projectedRunCodeCallCount: Int = 1,
        completedRunCodeCallCount: Int = 1,
        shellStreamNotificationCount: Int = 2
    ) -> PythonCLIToolTrafficEvidence {
        PythonCLIToolTrafficEvidence(
            transcriptRunCodeSnippets: snippets,
            transcriptRunCodeCallCount: transcriptRunCodeCallCount,
            transcriptCompletedShellEventCount: transcriptCompletedShellEventCount,
            projectedRunCodeCallCount: projectedRunCodeCallCount,
            completedRunCodeCallCount: completedRunCodeCallCount,
            shellStreamNotificationCount: shellStreamNotificationCount)
    }
}

/// What the honesty fixtures refused.
private enum HonestyFixtureError: Error {
    /// The `python3` shim answered with a failure, so no real
    /// interpreter is available to plant.
    case python3Unavailable(String)
}

/// The graders' honesty: the verdicts track the filesystem, the exit
/// codes, and the counts of the two evidence sides.
@Suite struct EvaluatorHonestyTests {
    // MARK: - PytestGreen

    /// A workspace whose pytest run exits nonzero grades FAIL, with
    /// the fabricated success-claiming transcript planted right beside
    /// it. The verdict reads the exit code, and never that file.
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
        let evidence = HonestyFixtures.toolTrafficEvidence(
            projectedRunCodeCallCount: 0,
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
        let evidence = HonestyFixtures.toolTrafficEvidence(
            snippets: [],
            transcriptRunCodeCallCount: 0,
            transcriptCompletedShellEventCount: 0)

        let verdict = PythonCLIGraders.toolTraffic(evidence: evidence)

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("transcript"))
    }

    /// The count of completed shell runs a transcript with a projection
    /// defect holds: many runs recorded, against the one notification
    /// the wire carried.
    private static let defectiveShellRunCount = 40

    /// A transcript that recorded many completed shell runs against one
    /// notification on the wire grades FAIL, although every reading is
    /// non-zero. Each completed shell run puts at least one
    /// notification on the wire, so fewer notifications than runs is a
    /// projection defect.
    @Test(.timeLimit(.minutes(1)))
    func toolTrafficFailsWhenTheWireCarriedFewerShellNotificationsThanRuns() {
        let evidence = HonestyFixtures.toolTrafficEvidence(
            transcriptCompletedShellEventCount: Self.defectiveShellRunCount,
            shellStreamNotificationCount: 1)

        let verdict = PythonCLIGraders.toolTraffic(evidence: evidence)

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("shell"))
    }

    /// The count of `runCode` calls a transcript with a projection
    /// defect announced, against the one call the wire carried.
    private static let defectiveRunCodeCallCount = 3

    /// A transcript that announced more `runCode` calls than the wire
    /// carried grades FAIL, although every reading is non-zero. Router
    /// emits one `toolCall` session event per announced call, so the
    /// wire holds one tool call for each of them.
    @Test(.timeLimit(.minutes(1)))
    func toolTrafficFailsWhenTheWireCarriedFewerRunCodeCallsThanTheTranscript() {
        let evidence = HonestyFixtures.toolTrafficEvidence(
            transcriptRunCodeCallCount: Self.defectiveRunCodeCallCount,
            projectedRunCodeCallCount: 1)

        let verdict = PythonCLIGraders.toolTraffic(evidence: evidence)

        #expect(!verdict.passed)
        #expect(verdict.rationale.contains("runCode"))
    }

    /// Agreeing readings grade PASS, so the FAIL cases above are
    /// judgments and not constants. The shell readings agree with two
    /// notifications for one completed run, because the wire promises
    /// at least one notification per run and never an exact count.
    @Test(.timeLimit(.minutes(1)))
    func toolTrafficPassesWhenBothReadingsAgree() {
        let evidence = HonestyFixtures.toolTrafficEvidence()

        let verdict = PythonCLIGraders.toolTraffic(evidence: evidence)

        #expect(verdict.passed)
    }
}
