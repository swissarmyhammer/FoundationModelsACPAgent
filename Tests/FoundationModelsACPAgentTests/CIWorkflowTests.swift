import Foundation
import Testing

/// Pins `.github/workflows/ci.yml` to the shared CI shape the org test
/// contract (swissarmyhammer/workflows' `docs/swift-ci.md`) asks for: one
/// job, which delegates to the shared `swift-ci.yaml` and selects the
/// integration suites by PACKAGE.
///
/// This repository obeys the contract in the document's Shape 2. The root
/// package holds the unit suites, and the nested `IntegrationTests`
/// package holds every suite that spawns a built binary, loads a real
/// model, or reaches the network. Thus `swift test` at the root runs the
/// unit suites and only the unit suites, and no environment variable
/// selects anything.
///
/// The suite pins seven properties of that shape: the `uses:` line names
/// the shared workflow at `@main`; exactly one job exists and it has no
/// `steps:` key, thus every test run is delegated;
/// `integration-package-path` names the nested package and
/// `integration-no-parallel` holds the live turns to one at a time; no
/// other selector or `integration-*` input is present; no source, test,
/// integration, or workflow file names either environment variable that
/// used to gate the slow suites; the triggers are a push to `main`, a
/// pull request, and a manual dispatch; and a new run of the same ref
/// cancels the run before it. A later edit that points `uses:` somewhere
/// else, adds a repository-local job that runs tests, drops an input, or
/// drops a trigger, makes this suite fail.
///
/// Two more cases pin the reader that the input assertions use, and not
/// the workflow file: ``inputValues(forKey:in:)`` finds a key in whichever
/// case the file spells it, and in whichever case a test asks for it.
/// GitHub Actions does the same, thus a reader that keeps the case lets a
/// forbidden input spelled `Integration-Skip:` go through this suite
/// without a report.
@Suite("CI workflow")
struct CIWorkflowTests {
    /// The full `uses:` value that `ci.yml` must delegate to, pinned to
    /// the `@main` ref the whole package family tracks.
    private static let sharedWorkflowReference =
        "uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main"

    /// The number of jobs `ci.yml` is allowed to declare. One job, and
    /// only one, keeps every test run inside the shared workflow.
    private static let allowedJobCount = 1

    /// The inputs `ci.yml` must pass, each with the value it must carry.
    ///
    /// `integration-package-path` alone starts the shared workflow's
    /// integration job, makes the unit job build the nested package on
    /// every run, and makes the integration job run
    /// `swift test --package-path` on it. `integration-no-parallel` holds
    /// the live model turns to one at a time: Swift Testing starts a time
    /// limit before a test takes a turnstile, so a parallel run spends the
    /// limit on queue time.
    private static let requiredInputs = [
        (input: "integration-package-path", value: "IntegrationTests"),
        (input: "integration-no-parallel", value: "true"),
    ]

    /// The inputs `ci.yml` must never pass.
    ///
    /// `test-filter` and `test-skip` would mean the root package still
    /// holds a suite the unit job must hold out, which is the split this
    /// repository moved into the nested package.
    /// `integration-filter` and `integration-skip` would narrow the
    /// integration job below the whole nested package, and a suite renamed
    /// away from the selector would then stop running with no report.
    /// `integration-gate-env` is the legacy path, and the shared workflow
    /// stops the job when it arrives beside a package path.
    /// `integration-metallib-glob` is unnecessary: Router's
    /// `MetalLibraryTestBootstrap` installs the shader-library link in
    /// process. `integration-root-products` is unnecessary too: the nested
    /// test target declares the root `acp-agent` and `acp-print` products,
    /// so SwiftPM builds both beside the nested test bundle, where
    /// `BuiltProductLocator` looks.
    private static let forbiddenInputs = [
        "test-filter",
        "test-skip",
        "integration-filter",
        "integration-skip",
        "integration-gate-env",
        "integration-metallib-glob",
        "integration-root-products",
    ]

    /// The directories the removed-gate walk reads: this package's own
    /// sources, its unit tests, its integration package, and its CI
    /// definition. The kanban records under `.kanban/` are history, and
    /// they keep the old names on purpose.
    private static let scannedDirectories = ["Sources", "Tests", "IntegrationTests", ".github"]

    /// The directory name the removed-gate walk steps over. A build
    /// directory holds checkouts of every dependency, so a walk into one
    /// reads gigabytes and reports another package's file.
    private static let buildDirectoryName = ".build"

    /// The environment variables that used to gate the slow suites, and
    /// that no file may name any more.
    ///
    /// Each name is joined from two parts so that this file, which the
    /// walk itself reads, does not hold a whole name and report itself.
    /// The prose below names neither one for the same reason.
    ///
    /// The second name is also the prefix of the removed dataset cap,
    /// which ended in `_SAMPLES`, so this substring search covers that
    /// name too.
    private static let removedEnvironmentGates = ["ACP" + "_TIER3", "ACP" + "_EVAL"]

    /// A `with:` block that spells every input this suite reads in a case
    /// that no lowercase text match finds.
    ///
    /// GitHub Actions resolves a `with:` key against the called workflow's
    /// `inputs:` without regard to case. Thus `Integration-Skip:` reaches
    /// the same input as `integration-skip:` does. This fixture is the
    /// proof that ``inputValues(forKey:in:)`` reads such a line, because a
    /// reader that misses it lets a forbidden input go through
    /// ``passesThePackagePathAndNothingElse()`` without a report.
    ///
    /// The value on each line is different from the others. Thus a match
    /// against the wrong line is visible in the failure message.
    private static let mixedCaseInputFixture = """
        jobs:
          ci:
            with:
              Integration-Package-Path: mixed-case-integration-package-path
              INTEGRATION-NO-PARALLEL: mixed-case-integration-no-parallel
              Test-Filter: mixed-case-test-filter
              TEST-SKIP: mixed-case-test-skip
              Integration-Filter: mixed-case-integration-filter
              Integration-Skip: mixed-case-integration-skip
              INTEGRATION-GATE-ENV: mixed-case-integration-gate-env
              Integration-Metallib-Glob: mixed-case-integration-metallib-glob
              INTEGRATION-ROOT-PRODUCTS: mixed-case-integration-root-products
        """

    /// The lowercase input name of each line of ``mixedCaseInputFixture``,
    /// with the value that line carries.
    ///
    /// The list holds every name of ``requiredInputs`` and of
    /// ``forbiddenInputs``. Thus each assertion of
    /// ``passesThePackagePathAndNothingElse()`` has its key covered.
    private static let mixedCaseFixtureExpectations = [
        (input: "integration-package-path", value: "mixed-case-integration-package-path"),
        (input: "integration-no-parallel", value: "mixed-case-integration-no-parallel"),
        (input: "test-filter", value: "mixed-case-test-filter"),
        (input: "test-skip", value: "mixed-case-test-skip"),
        (input: "integration-filter", value: "mixed-case-integration-filter"),
        (input: "integration-skip", value: "mixed-case-integration-skip"),
        (input: "integration-gate-env", value: "mixed-case-integration-gate-env"),
        (input: "integration-metallib-glob", value: "mixed-case-integration-metallib-glob"),
        (input: "integration-root-products", value: "mixed-case-integration-root-products"),
    ]

    @Test("ci.yml calls the shared swift-ci.yaml workflow at @main")
    func callsTheSharedWorkflow() throws {
        let lines = try Self.workflowLines()
        let callsShared = lines.contains { line in
            line.trimmingCharacters(in: .whitespaces) == Self.sharedWorkflowReference
        }
        #expect(
            callsShared,
            "ci.yml must contain \"\(Self.sharedWorkflowReference)\".")
    }

    @Test("ci.yml declares exactly one job, and that job delegates instead of running steps")
    func declaresOneDelegatingJob() throws {
        let lines = try Self.workflowLines()
        let jobs = Self.block(under: "jobs:", in: lines)

        // A job key is two-space-indented, e.g. "  ci:". Only the lines
        // below "jobs:" are read, because the two-space-indented children
        // of "on:" (push:, pull_request:, ...) have the same shape and
        // would otherwise count as jobs.
        let jobKeyPattern = try Regex(#"^  [a-zA-Z0-9_-]+:$"#)
        let jobKeys = jobs.filter { $0.wholeMatch(of: jobKeyPattern) != nil }
        #expect(
            jobKeys.count == Self.allowedJobCount,
            """
            ci.yml must declare exactly \(Self.allowedJobCount) job, which delegates to the shared \
            workflow, not repository-local unit or integration jobs; found job keys: \(jobKeys)
            """
        )

        // A "steps:" key is what a repository-local job that runs its own
        // commands looks like. A job that delegates has none.
        let stepKeys = jobs.filter { $0.trimmingCharacters(in: .whitespaces) == "steps:" }
        #expect(
            stepKeys.isEmpty,
            """
            ci.yml must declare no "steps:" key. Every test run is delegated to the shared \
            workflow; found \(stepKeys.count) such key(s).
            """
        )
    }

    @Test("ci.yml runs the nested package in the integration job and selects nothing else")
    func passesThePackagePathAndNothingElse() throws {
        let lines = try Self.workflowLines()

        for (key, expected) in Self.requiredInputs {
            let values = Self.inputValues(forKey: key, in: lines)
            #expect(
                values == [expected],
                """
                ci.yml must pass "\(key): \(expected)" exactly once; found: \(values)
                """
            )
        }

        for key in Self.forbiddenInputs {
            let values = Self.inputValues(forKey: key, in: lines)
            #expect(
                values.isEmpty,
                """
                ci.yml must pass no "\(key)" input: integration-package-path alone runs the whole \
                nested package, and the root package holds no suite the unit job must hold out; \
                found: \(values)
                """
            )
        }
    }

    @Test("an input key resolves in whichever case the workflow file spells it")
    func readsAnInputKeyThatTheFileSpellsInMixedCase() {
        let fixture = Self.lines(of: Self.mixedCaseInputFixture)
        for (input, value) in Self.mixedCaseFixtureExpectations {
            let values = Self.inputValues(forKey: input, in: fixture)
            #expect(
                values == [value],
                """
                GitHub Actions accepts a `with:` key in any case, thus "\(input)" must read the \
                mixed-case line of the fixture. A reader that keeps the case of the file lets a \
                forbidden input spelled "Integration-Skip:" go through the assertions above \
                without a report; found: \(values)
                """
            )
        }
    }

    @Test("an input key resolves in whichever case a test asks for it")
    func readsAnInputKeyThatTheTestAsksForInMixedCase() throws {
        let lines = try Self.workflowLines()

        // ci.yml spells its own keys in lower case, thus this is the other
        // half of the same contract: the asked key may carry any case.
        for (key, expected) in Self.requiredInputs {
            for spelling in [key.uppercased(), key.capitalized] {
                let values = Self.inputValues(forKey: spelling, in: lines)
                #expect(
                    values == [expected],
                    """
                    An input name is case-insensitive on both sides, thus "\(spelling)" must read \
                    the "\(key)" line of ci.yml. A reader that keeps the case of the asked key \
                    makes each assertion above depend on one spelling; found: \(values)
                    """
                )
            }
        }
    }

    @Test("no source, test, integration, or workflow file names a removed environment gate")
    func namesNoRemovedEnvironmentGate() throws {
        let root = try PackageRoot.directory()
        var offenders: [String] = []
        for directory in Self.scannedDirectories {
            let base = root.appendingPathComponent(directory, isDirectory: true)
            guard
                let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else {
                Issue.record("Cannot walk \(base.path).")
                continue
            }
            for case let url as URL in walk {
                if url.lastPathComponent == Self.buildDirectoryName {
                    walk.skipDescendants()
                    continue
                }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for gate in Self.removedEnvironmentGates where text.contains(gate) {
                    offenders.append("\(url.path) names \(gate)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            The environment gates are removed: \(Self.removedEnvironmentGates) select no test any \
            more, and the nested IntegrationTests package carries the split instead. No source, \
            test, integration, or workflow file may name one; found: \(offenders)
            """
        )
    }

    @Test("ci.yml runs on a push to main, on a pull request, and on a manual dispatch")
    func declaresTheExpectedTriggers() throws {
        let lines = try Self.workflowLines()
        let triggers = Self.block(under: "on:", in: lines)

        // Matched with the indentation kept, because the indentation is
        // what makes "branches: [main]" a child of "push:" and not of the
        // "on:" block itself.
        let expectedTriggerLines = [
            "  push:",
            "    branches: [main]",
            "  pull_request:",
            "  workflow_dispatch:",
        ]
        for expected in expectedTriggerLines {
            #expect(
                triggers.contains(Substring(expected)),
                """
                ci.yml must declare the line "\(expected)" in its "on:" block; found: \(triggers)
                """
            )
        }
    }

    @Test("ci.yml cancels a run that a newer run of the same ref supersedes")
    func declaresConcurrencyThatCancelsInProgress() throws {
        let lines = try Self.workflowLines()
        let concurrency = Self.block(under: "concurrency:", in: lines)

        // The group must vary with the ref. A constant group would cancel
        // runs of unrelated branches against each other.
        let groupIsPerRef = concurrency.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("group:") && trimmed.contains("github.ref")
        }
        #expect(
            groupIsPerRef,
            """
            ci.yml must set a "concurrency" group that varies with github.ref; found: \(concurrency)
            """
        )

        let cancelsInProgress = concurrency.contains { line in
            line.trimmingCharacters(in: .whitespaces) == "cancel-in-progress: true"
        }
        #expect(
            cancelsInProgress,
            """
            ci.yml must set "cancel-in-progress: true" in its "concurrency" block; found: \
            \(concurrency)
            """
        )
    }

    /// Reads `.github/workflows/ci.yml` from the repository root.
    ///
    /// - Returns: Each line of the workflow file.
    /// - Throws: An error when the root cannot be resolved, or when the
    ///   file cannot be read.
    private static func workflowLines() throws -> [Substring] {
        let workflow = try PackageRoot.directory()
            .appendingPathComponent(".github/workflows/ci.yml")
        return Self.lines(of: try String(contentsOf: workflow, encoding: .utf8))
    }

    /// Cuts workflow text into lines.
    ///
    /// ``workflowLines()`` and the in-test fixtures both go through here,
    /// thus a fixture has the same shape as the real file. An empty line
    /// stays, because a reader must step over it as the file has it.
    ///
    /// - Parameter text: The text of a workflow file, or of a fixture.
    /// - Returns: Each line of that text.
    private static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The value of every `key: value` line of a workflow file whose key
    /// matches `key` without regard to case.
    ///
    /// The case-insensitive read is what GitHub Actions itself does: it
    /// resolves a `with:` key against the called workflow's `inputs:`
    /// without regard to case, so `Integration-Skip:` switches the
    /// integration job on exactly as `integration-skip:` does. A
    /// case-sensitive read would let that spelling through.
    ///
    /// A comment line does not match, because its key carries the leading
    /// `#`. Thus the header comment may name an input in prose.
    ///
    /// - Parameters:
    ///   - key: An input name, written without its colon, e.g.
    ///     `"integration-package-path"`.
    ///   - lines: The lines of the workflow file.
    /// - Returns: The values, in file order, or an empty array when no
    ///   line carries that key.
    private static func inputValues(forKey key: String, in lines: [Substring]) -> [String] {
        lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            guard trimmed[..<colon].lowercased() == key.lowercased() else { return nil }
            return trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    /// The lines nested below the top-level `key` of a workflow file.
    ///
    /// The block starts at the line after `key` and stops at the next line
    /// that has content in column one, that is, at the next top-level key.
    /// Blank lines stay in the block, because they do not end it.
    ///
    /// - Parameters:
    ///   - key: A top-level key, written with its colon, e.g. `"jobs:"`.
    ///   - lines: The lines of the workflow file.
    /// - Returns: The nested lines, or an empty array when `key` is
    ///   absent.
    private static func block(under key: String, in lines: [Substring]) -> [Substring] {
        guard let keyIndex = lines.firstIndex(of: Substring(key)) else { return [] }
        let below = lines[lines.index(after: keyIndex)...]
        return Array(below.prefix { $0.isEmpty || $0.hasPrefix(" ") })
    }
}
