import ArgumentParser
import Foundation
import FoundationModelsACPAgent

extension AcpAgentCommand {
    /// `acp-agent instructions`: the compiled-in instructions floor, and
    /// its wholesale replacement in a layer (cli-plan.md §5.3).
    struct Instructions: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "instructions",
            abstract: "Work with the instructions text.",
            subcommands: [Eject.self])

        /// `instructions eject`: write `Instructions.md` into a layer.
        ///
        /// The prompt floor is compiled in, and a layer file replaces it
        /// wholesale: the nearest layer wins. A person cannot edit what they cannot
        /// read, so this command writes the compiled-in text out for them.
        /// After an eject the file on disk is the prompt, and every edit
        /// to it is the whole new prompt.
        struct Eject: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "eject",
                abstract: "Write Instructions.md into a layer.",
                discussion: """
                    The written path goes to stdout. The command refuses to \
                    replace an Instructions.md that is already in the layer, \
                    and it names the flag that permits the replacement.
                    """)

            /// The `--cwd` option (§5.10).
            @OptionGroup var workingDirectoryOptions: WorkingDirectoryOptions

            /// The `--home` option, which roots the user layer.
            @OptionGroup var homeOptions: HomeOptions

            /// Which layer receives the file. The project layer is the
            /// default, which matches `config init`.
            @Flag var layer: LayerSelection = .project

            /// Whether an `Instructions.md` that is already in the layer is
            /// replaced.
            @Flag(
                name: .customLong(LayerFileWriter.forceFlagName),
                help: "Replace an Instructions.md that is already in the layer."
            )
            var overwrites = false

            mutating func run() throws {
                try report(environment: homeOptions.environment(over: ProcessInfo.processInfo.environment))
                    .write()
            }

            /// Writes the file and builds the report: the written path, and
            /// nothing for stderr.
            ///
            /// - Parameter environment: The environment the home of the
            ///   stack is read from (``AgentComposition/home(environment:)``).
            /// - Returns: The report.
            /// - Throws: `DotfolderNameError` when the dotfolder name is
            ///   refused, or what ``LayerFileWriter/write(_:named:into:of:overwrites:)``
            ///   throws — above all the refusal to overwrite.
            func report(environment: [String: String]) throws -> CommandReport {
                let stack = try AgentComposition.makeConfigurationLoader(
                    workingDirectory: workingDirectoryOptions.directoryURL, environment: environment
                ).stack
                let url = try LayerFileWriter.write(
                    BuiltinInstructions.text,
                    named: InstructionsAssembler.instructionsFileName,
                    into: layer, of: stack, overwrites: overwrites)
                return CommandReport(standardOutput: url.path + "\n", standardErrorLines: [])
            }
        }
    }
}
