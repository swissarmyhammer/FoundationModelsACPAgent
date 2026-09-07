import ArgumentParser
import Foundation
import FoundationModelsExtras

/// Which layer of the dotfolder stack a written file goes into
/// (cli-plan.md §5.3, §5.11): the user layer, or the project layer.
///
/// `instructions eject` writes `Instructions.md`, and `config init` writes
/// `config.yaml`. The two commands write different files into the same two
/// layers, so they share this one flag set. The default is the project
/// layer for both, because that is the layer a person keeps beside the
/// repository.
///
/// The shipped-defaults layer is absent on purpose: it is the consumer's
/// own directory, and no command writes into it.
enum LayerSelection: String, EnumerableFlag {
    /// The user layer, `$XDG_CONFIG_HOME/<name>/`.
    case user

    /// The project layer, `<cwd>/.<name>/`.
    case project

    /// The word the `/config export` slash command spells the user layer
    /// with (plan.md §14.1, cli-plan.md §5.11).
    ///
    /// The two front doors of one directory take two words: `config init`
    /// takes `--user`, and `/config export` takes `home`. They are one
    /// layer, not two: both write
    /// `$XDG_CONFIG_HOME/<name>/config.yaml`. This is the one place that
    /// says so, and the `--user` help text below quotes it, so a person
    /// who reads `--help` is not left to guess either.
    static let userLayerExportWord = "home"

    /// The stack source this selection names.
    var source: DotfolderStack.Source {
        switch self {
        case .user:
            return .user
        case .project:
            return .project
        }
    }

    /// The help text of one flag, so `--help` says which directory each
    /// layer is.
    ///
    /// - Parameter value: The flag to describe.
    /// - Returns: The help text.
    static func help(for value: LayerSelection) -> ArgumentHelp? {
        switch value {
        case .user:
            return """
                Write into the user layer, $XDG_CONFIG_HOME/\(AgentComposition.dotfolderName)/. \
                The /config export slash command spells this same layer \(userLayerExportWord).
                """
        case .project:
            return
                "Write into the project layer, <cwd>/.\(AgentComposition.dotfolderName)/. This is the default."
        }
    }
}

/// The refusal that the layer already holds the file (cli-plan.md §5.3).
///
/// A person edits the file a write put there, so a second write must never
/// take that edit away unasked. The message names the flag that permits
/// the replacement, so the recourse is in the refusal itself.
struct LayerFileExistsError: Error, CustomStringConvertible {
    /// The path of the file that is already on disk.
    let path: String

    var description: String {
        "\(path) already exists; pass \(LayerFileWriter.forceFlagSpelling) to overwrite it"
    }
}

/// The refusal that the stack holds no layer of the selected kind, so
/// there is no directory to write into.
struct LayerMissingError: Error, CustomStringConvertible {
    /// The layer the stack does not hold.
    let selection: LayerSelection

    var description: String {
        "the configuration stack holds no \(selection.rawValue) layer"
    }
}

/// Writes one file into one layer of a dotfolder stack — the one writer
/// `instructions eject` and `config init` share (cli-plan.md §5.3, §5.11).
///
/// The overwrite guard is why this is one place. Both commands write a
/// file that a person then edits, and both must refuse to replace that
/// edit until the person asks. One guard cannot drift from itself.
///
/// The layer root comes from the stack, so no code here repeats how a
/// layer path is built.
enum LayerFileWriter {
    /// The flag name that permits an overwrite. A subcommand declares its
    /// flag with this name, and ``LayerFileExistsError`` names it in the
    /// refusal, so one declaration spells it for both.
    static let forceFlagName = "force"

    /// ``forceFlagName`` as a person types it on the command line.
    static let forceFlagSpelling = "--" + forceFlagName

    /// Writes `text` as `fileName` into the layer `selection` names.
    ///
    /// The guard runs before the directory is created, so a refused write
    /// changes no file and makes no directory.
    ///
    /// - Parameters:
    ///   - text: The file content to write.
    ///   - fileName: The file name inside the layer root, e.g.
    ///     `Instructions.md`.
    ///   - selection: Which layer receives the file.
    ///   - stack: The stack whose layer roots the file goes into.
    ///   - overwrites: Whether a file that is already there is replaced.
    /// - Returns: The path the file was written to.
    /// - Throws: ``LayerMissingError`` when the stack holds no layer of
    ///   that kind, ``LayerFileExistsError`` when the file is already
    ///   there and `overwrites` is `false`, or the file-system error of
    ///   the directory creation or the write.
    static func write(
        _ text: String, named fileName: String, into selection: LayerSelection,
        of stack: DotfolderStack, overwrites: Bool
    ) throws -> URL {
        guard let layer = stack.layers.first(where: { $0.source == selection.source }) else {
            throw LayerMissingError(selection: selection)
        }
        let url = layer.root.appendingPathComponent(fileName)
        guard overwrites || !FileManager.default.fileExists(atPath: url.path) else {
            throw LayerFileExistsError(path: url.path)
        }
        try FileManager.default.createDirectory(at: layer.root, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
