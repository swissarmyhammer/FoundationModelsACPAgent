import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

// MARK: - The ungated eval units (plan.md §20.3's workflow note)
//
// The dataset shape and the subject wiring are provable with no real
// model: a scripted backend plays one code-mode turn that really
// writes a file and really runs a sandboxed shell command, and the
// subject host drives it over the same ACP wire the gated tier uses.

/// The dataset's shape: the size Apple's guidance asks for, unique
/// ids, and complete ground truth on every sample.
@Suite struct PythonCLIDatasetTests {
    /// The smallest dataset plan.md §20.3 asks for.
    private static let minimumSampleCount = 20

    /// The largest dataset plan.md §20.3 asks for, before
    /// `SampleGenerator` scaling.
    private static let maximumSampleCount = 30

    @Test func theDatasetHoldsTwentyToThirtyUniquelyNamedSamples() {
        let specs = PythonCLIDataset.sampleSpecs
        #expect(specs.count >= Self.minimumSampleCount)
        #expect(specs.count <= Self.maximumSampleCount)
        #expect(Set(specs.map(\.id)).count == specs.count)
        #expect(Set(specs.map(\.moduleName)).count == specs.count)
    }

    @Test func everySampleCarriesCompleteGroundTruth() {
        for spec in PythonCLIDataset.sampleSpecs {
            let expected = PythonCLIDataset.expectedOutcome(of: spec)
            #expect(!expected.expectedOutput.isEmpty)
            #expect(!expected.arguments.isEmpty)
            #expect(expected.requiredFiles.contains(PythonCLIDataset.manifestFilePath))
            #expect(expected.requiredFiles.contains("\(spec.moduleName).py"))
            #expect(expected.requiredFiles.contains(PythonCLIDataset.testFilePath))
            #expect(expected.dependencyPackage == PythonCLIDataset.dependencyPackage)
            #expect(expected.pytestGreen == nil)
            #expect(expected.stats == nil)
        }
    }

    /// The prompt names the two verb paths and the workspace path, so
    /// the shell steps never fall back to the refused process working
    /// directory.
    @Test func thePromptNamesTheVerbPathsAndTheWorkspace() throws {
        let spec = try #require(PythonCLIDataset.sampleSpecs.first)
        let workspace = makeResolvedDirectory(label: "PythonCLIDataset-prompt")
        let prompt = PythonCLIDataset.prompt(of: spec, workspace: workspace)
        #expect(prompt.contains(PythonCLIToolTrafficEvidence.filesVerbPathPrefix))
        #expect(prompt.contains(PythonCLIToolTrafficEvidence.shellExecuteVerbPath))
        #expect(prompt.contains(workspace.path))
        #expect(prompt.contains(spec.expectedOutput))
    }
}

/// The subject wiring over a scripted backend: one real code-mode
/// turn through the ACP wire, with real `files` and `shell` and the
/// recording pipeline.
@Suite struct PythonCLISubjectTests {
    /// The marker file the scripted snippet writes.
    private static let markerFileName = "eval-marker.txt"

    /// The marker content the scripted snippet writes.
    private static let markerContent = "the scripted subject wrote this"

    /// The line the scripted shell command prints.
    private static let shellLine = "scripted-shell-line"

    /// The number of seconds in ``scriptedIdleDeadline``.
    private static let scriptedIdleDeadlineSeconds = 60

    /// How long the scripted turn may run before the wait gives up.
    private static let scriptedIdleDeadline: Duration = .seconds(scriptedIdleDeadlineSeconds)

    /// The `wait` plays after the snippet: one settles the `runCode`
    /// run, and one joins the nested background shell run.
    private static let waitStepCount = 2

    /// The snippet of the scripted turn: a files write, then a shell
    /// run in the workspace. Each step returns its in-band correction
    /// when one arrives, so a failure names itself.
    ///
    /// - Parameter workspace: The session working directory.
    /// - Returns: The snippet.
    /// - Throws: The encoding error of the embedded path literal.
    private static func makeSnippet(workspace: URL) throws -> String {
        let pathLiteral = String(
            decoding: try JSONEncoder().encode(workspace.path), as: UTF8.self)
        return """
            const written = await tools.files.write({ path: "\(markerFileName)", content: "\(markerContent)" });
            if (written.correction) { return written.correction; }
            return await tools.shell.execute({ command: "echo \(shellLine)", workingDirectory: \(pathLiteral) });
            """
    }

    /// The scripted steps of one subject turn.
    ///
    /// - Parameter workspace: The session working directory.
    /// - Returns: The steps.
    /// - Throws: The arguments-encoding error.
    private static func makeScript(workspace: URL) throws -> [ScriptedTurnStep] {
        let arguments = String(
            decoding: try JSONEncoder().encode(["code": try makeSnippet(workspace: workspace)]),
            as: UTF8.self)
        let waits = [ScriptedTurnStep](
            repeating: .toolCall(name: "wait", argumentsJSON: "{}"),
            count: waitStepCount)
        return [.toolCall(name: "runCode", argumentsJSON: arguments)] + waits + [.endTurn]
    }

    /// Wires a scripted host and drives one subject turn.
    ///
    /// - Parameter label: The directory label of the calling test.
    /// - Returns: The host and the finished run.
    /// - Throws: Whatever the wiring or the drive throws.
    private static func runScriptedTurn(
        label: String
    ) async throws -> (host: PythonCLISubjectHost, run: PythonCLITurnRun) {
        let workspace = makeResolvedDirectory(label: "\(label)-workspace")
        let userDirectory = try PythonCLISubjectHost.prepareUserDirectory(
            label: "\(label)-user")
        // `recordingsDirectory` switches the Router recorder on; with
        // none the recorder is the no-op sink and no events land, no
        // matter what recording root the session resolves.
        let agent = try await makeStubAgent(
            name: AgentClientHarness.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "\(label)-recordings"),
            userDirectory: userDirectory,
            loader: makeScriptedModelLoader(script: try makeScript(workspace: workspace)))
        let host = try await PythonCLISubjectHost.make(
            agent: agent, userDirectory: userDirectory)
        let run = try await host.runSample(
            prompt: "Run the scripted build turn",
            workspace: workspace,
            idleDeadline: scriptedIdleDeadline)
        return (host, run)
    }

    /// The subject drives the wire to idle, the snippet's file lands
    /// on disk, and every tool-traffic reading — transcript and wire —
    /// is present on the run's evidence.
    @Test(.timeLimit(.minutes(1)))
    func theScriptedSubjectDrivesTheWireAndCollectsAgreeingEvidence() async throws {
        let (host, run) = try await Self.runScriptedTurn(label: "PythonCLISubject-evidence")

        // The disk is the truth (plan.md §20.1).
        let marker = try textOnDisk(
            at: run.workspace.appendingPathComponent(Self.markerFileName))
        #expect(marker == Self.markerContent)

        // The acceptance criteria's client-state readings.
        #expect(run.stopReason == .endTurn)
        #expect(run.turnStateIdle)
        #expect(run.lastStopReason == .endTurn)

        // The two tool-traffic readings agree on a real run, so the
        // grader passes real traffic and the honesty suite's failing
        // evidence stays a judgment.
        let evidence = run.toolTrafficEvidence
        #expect(evidence.completedRunCodeCallCount >= 1)
        #expect(evidence.shellStreamNotificationCount >= 1)
        #expect(evidence.transcriptCompletedShellEventCount >= 1)
        let snippets = evidence.transcriptRunCodeSnippets.joined(separator: "\n")
        #expect(snippets.contains(PythonCLIToolTrafficEvidence.filesVerbPathPrefix))
        #expect(snippets.contains(PythonCLIToolTrafficEvidence.shellExecuteVerbPath))
        #expect(PythonCLIGraders.toolTraffic(evidence: evidence).passed)

        await host.close()
    }

    /// Grading records every verdict and the stats, deletes the
    /// workspace, and keeps the transcripts of a failed run.
    @Test(.timeLimit(.minutes(1)))
    func gradingRecordsVerdictsDeletesTheWorkspaceAndKeepsFailedTranscripts() async throws {
        let (host, run) = try await Self.runScriptedTurn(label: "PythonCLISubject-grading")
        var expected = PythonCLIDataset.expectedOutcome(
            of: try #require(PythonCLIDataset.sampleSpecs.first))
        expected = PythonCLIOutcome(
            sampleID: expected.sampleID,
            moduleName: expected.moduleName,
            arguments: expected.arguments,
            expectedOutput: expected.expectedOutput,
            requiredFiles: [Self.markerFileName],
            dependencyPackage: expected.dependencyPackage)

        let produced = await PythonCLISubjectHost.gradedOutcome(of: run, expected: expected)
        await host.close()

        // The scripted turn wrote the marker, so the file check
        // passes; no venv exists, so the pytest re-run fails — and the
        // failed run keeps its transcripts while the workspace is
        // gone.
        #expect(produced.filesPresent?.passed == true)
        #expect(produced.pytestGreen?.passed == false)
        #expect(produced.cliRuns?.passed == false)
        #expect(produced.toolTraffic?.passed == true)
        #expect(produced.stopReason == String(describing: StopReason.endTurn))
        let stats = try #require(produced.stats)
        #expect(stats.turnCount == 1)
        #expect(stats.toolCallCount >= 1)
        #expect(stats.notificationCount >= 1)
        #expect(stats.elapsedSeconds > 0)
        #expect(!FileManager.default.fileExists(atPath: run.workspace.path))
        #expect(FileManager.default.fileExists(atPath: run.recordingRoot.path))
    }
}
