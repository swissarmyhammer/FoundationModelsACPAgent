import Evaluations
import Foundation

// MARK: - The hand-written dataset (plan.md §20.3)
//
// 24 variants of "build a small Python CLI", per Apple's guidance to
// start with 20-30 hand-written samples. Every variant asks for the
// same project shape — pyproject.toml, a click CLI module, pytest
// tests, a project-local venv, pytest green, then run it — and varies
// the CLI's behavior and its fixed input/output pair.

/// One hand-written sample: a CLI behavior and its fixed
/// input/output pair.
struct PythonCLISampleSpec: Sendable, Equatable {
    /// The stable sample id, unique inside the dataset.
    let id: String

    /// The Python module the CLI runs as: `python -m <moduleName>`.
    let moduleName: String

    /// The CLI behavior, one sentence, spliced into the prompt.
    let behavior: String

    /// The fixed input: the CLI arguments of the verification run.
    let arguments: [String]

    /// The fixed output the verification run must print.
    let expectedOutput: String
}

/// The dataset and the prompt of the Python CLI eval.
enum PythonCLIDataset {
    /// The third-party package every sample must use.
    static let dependencyPackage = "click"

    /// The workspace-relative test file every sample must write.
    static let testFilePath = "tests/test_cli.py"

    /// The workspace-relative project manifest every sample must write.
    static let manifestFilePath = "pyproject.toml"

    /// The hand-written sample specs, in dataset order.
    static let sampleSpecs: [PythonCLISampleSpec] = [
        PythonCLISampleSpec(
            id: "greet", moduleName: "greet_cli",
            behavior:
                "takes a --name option and prints exactly: Hello, <name>!",
            arguments: ["--name", "World"], expectedOutput: "Hello, World!"),
        PythonCLISampleSpec(
            id: "shout", moduleName: "shout_cli",
            behavior: "takes one TEXT argument and prints it upper-cased",
            arguments: ["make it loud"], expectedOutput: "MAKE IT LOUD"),
        PythonCLISampleSpec(
            id: "add", moduleName: "add_cli",
            behavior: "takes two integer arguments A and B and prints their sum",
            arguments: ["19", "23"], expectedOutput: "42"),
        PythonCLISampleSpec(
            id: "multiply", moduleName: "multiply_cli",
            behavior: "takes two integer arguments A and B and prints their product",
            arguments: ["6", "7"], expectedOutput: "42"),
        PythonCLISampleSpec(
            id: "subtract", moduleName: "subtract_cli",
            behavior: "takes two integer arguments A and B and prints A minus B",
            arguments: ["50", "8"], expectedOutput: "42"),
        PythonCLISampleSpec(
            id: "reverse", moduleName: "reverse_cli",
            behavior: "takes one TEXT argument and prints it reversed",
            arguments: ["stressed"], expectedOutput: "desserts"),
        PythonCLISampleSpec(
            id: "repeat", moduleName: "repeat_cli",
            behavior:
                "takes one TEXT argument and a --count integer option and prints the text repeated that many times with no separator",
            arguments: ["ab", "--count", "3"], expectedOutput: "ababab"),
        PythonCLISampleSpec(
            id: "words", moduleName: "words_cli",
            behavior: "takes one TEXT argument and prints the number of whitespace-separated words",
            arguments: ["the quick brown fox"], expectedOutput: "4"),
        PythonCLISampleSpec(
            id: "chars", moduleName: "chars_cli",
            behavior: "takes one TEXT argument and prints the number of characters in it",
            arguments: ["abcdef"], expectedOutput: "6"),
        PythonCLISampleSpec(
            id: "celsius", moduleName: "celsius_cli",
            behavior:
                "takes one integer CELSIUS argument and prints the Fahrenheit value as an integer",
            arguments: ["100"], expectedOutput: "212"),
        PythonCLISampleSpec(
            id: "fahrenheit", moduleName: "fahrenheit_cli",
            behavior:
                "takes one integer FAHRENHEIT argument and prints the Celsius value as an integer",
            arguments: ["212"], expectedOutput: "100"),
        PythonCLISampleSpec(
            id: "even", moduleName: "even_cli",
            behavior: "takes one integer argument and prints even when it is even and odd when it is odd",
            arguments: ["42"], expectedOutput: "even"),
        PythonCLISampleSpec(
            id: "maximum", moduleName: "maximum_cli",
            behavior: "takes three integer arguments and prints the largest",
            arguments: ["11", "42", "7"], expectedOutput: "42"),
        PythonCLISampleSpec(
            id: "minimum", moduleName: "minimum_cli",
            behavior: "takes three integer arguments and prints the smallest",
            arguments: ["11", "42", "7"], expectedOutput: "7"),
        PythonCLISampleSpec(
            id: "sort", moduleName: "sort_cli",
            behavior:
                "takes a comma-separated TEXT argument of words and prints them sorted ascending, joined by commas",
            arguments: ["pear,apple,plum"], expectedOutput: "apple,pear,plum"),
        PythonCLISampleSpec(
            id: "unique", moduleName: "unique_cli",
            behavior:
                "takes a comma-separated TEXT argument of words and prints the distinct words in first-seen order, joined by commas",
            arguments: ["a,b,a,c,b"], expectedOutput: "a,b,c"),
        PythonCLISampleSpec(
            id: "initials", moduleName: "initials_cli",
            behavior:
                "takes one TEXT argument of space-separated words and prints the first letter of each word upper-cased with no separator",
            arguments: ["ada lovelace"], expectedOutput: "AL"),
        PythonCLISampleSpec(
            id: "vowels", moduleName: "vowels_cli",
            behavior: "takes one TEXT argument and prints the number of vowels (aeiou) in it",
            arguments: ["banana"], expectedOutput: "3"),
        PythonCLISampleSpec(
            id: "palindrome", moduleName: "palindrome_cli",
            behavior:
                "takes one TEXT argument and prints yes when it reads the same reversed and no otherwise",
            arguments: ["racecar"], expectedOutput: "yes"),
        PythonCLISampleSpec(
            id: "factorial", moduleName: "factorial_cli",
            behavior: "takes one non-negative integer argument and prints its factorial",
            arguments: ["5"], expectedOutput: "120"),
        PythonCLISampleSpec(
            id: "fibonacci", moduleName: "fibonacci_cli",
            behavior:
                "takes one integer N argument and prints the N-th Fibonacci number, with fib(0) = 0 and fib(1) = 1",
            arguments: ["10"], expectedOutput: "55"),
        PythonCLISampleSpec(
            id: "title", moduleName: "title_cli",
            behavior: "takes one TEXT argument and prints it title-cased with str.title()",
            arguments: ["the quick fox"], expectedOutput: "The Quick Fox"),
        PythonCLISampleSpec(
            id: "join", moduleName: "join_cli",
            behavior:
                "takes a comma-separated TEXT argument and a --separator option and prints the pieces joined by the separator",
            arguments: ["a,b,c", "--separator", "-"], expectedOutput: "a-b-c"),
        PythonCLISampleSpec(
            id: "digits", moduleName: "digits_cli",
            behavior: "takes one TEXT argument and prints only its digit characters, in order",
            arguments: ["a1b2c3"], expectedOutput: "123"),
    ]

    /// The workspace-relative files ``PythonCLIEvalMetric/filesPresent``
    /// checks for `spec`.
    ///
    /// - Parameter spec: The sample spec.
    /// - Returns: The manifest, the module file, and the test file.
    static func requiredFiles(of spec: PythonCLISampleSpec) -> [String] {
        [manifestFilePath, "\(spec.moduleName).py", testFilePath]
    }

    /// The ground-truth outcome of `spec` — the `expected` side of a
    /// sample, with no produced fields.
    ///
    /// - Parameter spec: The sample spec.
    /// - Returns: The expected outcome.
    static func expectedOutcome(of spec: PythonCLISampleSpec) -> PythonCLIOutcome {
        PythonCLIOutcome(
            sampleID: spec.id,
            moduleName: spec.moduleName,
            arguments: spec.arguments,
            expectedOutput: spec.expectedOutput,
            requiredFiles: requiredFiles(of: spec),
            dependencyPackage: dependencyPackage)
    }

    /// The one shell command of a sample's build step: the venv, the
    /// package install, the pytest run, and the CLI verification run,
    /// chained so one background shell run carries the whole build.
    ///
    /// - Parameter spec: The sample spec.
    /// - Returns: The command.
    static func buildCommand(of spec: PythonCLISampleSpec) -> String {
        let verifyArguments = spec.arguments.map(shellQuoted(_:)).joined(separator: " ")
        return "python3 -m venv .venv"
            + " && .venv/bin/python -m pip install \(dependencyPackage) pytest"
            + " && .venv/bin/python -m pytest -q"
            + " && .venv/bin/python -m \(spec.moduleName) \(verifyArguments)"
    }

    /// `argument` for the chained build command: bare when it carries
    /// no whitespace, and double-quoted otherwise. Most samples then
    /// need no quotes at all, which keeps the snippet in the prompt
    /// free of JSON escape burden — the measured cause of the small
    /// models\' malformed step-2 tool calls.
    private static func shellQuoted(_ argument: String) -> String {
        guard argument.contains(where: \.isWhitespace) else {
            return argument
        }
        return "\"\(argument)\""
    }

    /// The prompt of one sample: the whole build task, phrased as
    /// explicit `runCode` calls, with the fixed verification pair
    /// spelled out.
    ///
    /// Two shapes in this prompt are load-bearing:
    ///
    /// - It opens with "Call the runCode tool. Pass one argument named
    ///   code" — the small local models emit malformed tool calls for
    ///   vaguer phrasings, and a malformed call fails the whole turn
    ///   (`RejectedToolCall`, measured on the 2026-09-02 probe runs).
    /// - Every shell step names `workingDirectory` because the shell
    ///   verb's own default is the agent process current directory,
    ///   which the sandbox refuses (plan.md §11.7; the TierTwoTests
    ///   stream proof records the same rule).
    ///
    /// - Parameters:
    ///   - spec: The sample spec.
    ///   - workspace: The session working directory of the sample.
    /// - Returns: The prompt text.
    static func prompt(of spec: PythonCLISampleSpec, workspace: URL) -> String {
        let workspacePath = workspace.path
        return """
            Build a small Python command line program in this workspace, with the runCode tool.

            Step 1. Call the runCode tool. Pass one argument named code whose value is a \
            JavaScript snippet that writes three files with await tools.files.write({ path, content }):
            - \(manifestFilePath) — a project named \(spec.moduleName) that depends on \(dependencyPackage)
            - \(spec.moduleName).py — a \(dependencyPackage) CLI that \(spec.behavior). \
            It must run with: python -m \(spec.moduleName)
            - \(testFilePath) — pytest tests that cover the CLI behavior with click.testing.CliRunner
            Write each file content as ONE single-line JavaScript string: use \\n escape \
            sequences for line breaks, and never a real line break inside a string.

            Step 2. Call the runCode tool again. Pass one argument named code whose value is \
            this JavaScript snippet, exactly as written, with the single quotes kept:
            return await tools.shell.execute({ command: '\(buildCommand(of: spec))', \
            workingDirectory: '\(workspacePath)' });
            Then call the wait tool with the returned completionToken until the report shows \
            state "complete".

            The last part of the command must print exactly: \(spec.expectedOutput)
            When pytest or the CLI fails, fix the files with another runCode call and run the \
            step 2 snippet again.
            """
    }

    /// The `ArrayLoader` of the dataset: one `ModelSample` per spec, in
    /// dataset order, capped at `limit`.
    ///
    /// - Parameter limit: The largest number of samples to load, or
    ///   `nil` for the whole dataset. A gated evidence run caps the
    ///   dataset with `ACP_EVAL_SAMPLES`.
    /// - Returns: The loader.
    static func makeLoader(limit: Int? = nil) -> ArrayLoader<ModelSample<PythonCLIOutcome>> {
        let specs = limit.map { Array(sampleSpecs.prefix($0)) } ?? sampleSpecs
        return ArrayLoader(
            samples: specs.map { spec in
                ModelSample(prompt: spec.id, expected: expectedOutcome(of: spec))
            })
    }

    /// The spec of `sampleID`, or `nil` for an id outside the dataset.
    ///
    /// - Parameter sampleID: The id to look up.
    /// - Returns: The spec, or `nil`.
    static func spec(of sampleID: String) -> PythonCLISampleSpec? {
        sampleSpecs.first { $0.id == sampleID }
    }
}
