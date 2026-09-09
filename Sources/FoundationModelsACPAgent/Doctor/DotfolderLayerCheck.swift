import Foundation
import FoundationModelsExtras

/// The finding of one dotfolder layer directory (cli-plan.md §5.12).
///
/// Two components report a row for each layer of their own stack:
/// ``ConfigurationDoctor`` for the configuration stack, and
/// ``RuntimeDoctor`` for the skills stack. The row is the same shape in
/// each case — the layer is not on disk, or it is there and cannot be
/// read, or it is there and can be read — so the name, the three rows and
/// the `chmod` fix are written one time here, and each component gives
/// only the words that are its own.
///
/// A layer that is not on disk always passes. Both stacks are built to
/// work with no file at all, so a missing layer is what a fresh install
/// looks like.
///
/// The write test is an option, because only the configuration stack is
/// written to. A component that only reads its layers asks for it not.
enum DotfolderLayerCheck {
    /// The command that makes a layer directory writable. A `doctor` fix
    /// names it, so a person has the whole repair in one line.
    private static let writeFix = "chmod u+w"

    /// The words one component says about the layers of its own stack.
    ///
    /// The shape of each sentence is the same in every component, so this
    /// type carries only the part that changes.
    struct Wording {
        /// Why a layer that is not on disk is no fault. It completes the
        /// sentence "<path> is not on disk, and ".
        var missingReason: String

        /// The noun that names the stack in a check name, as in "the
        /// skills project layer". It is empty when the check names the
        /// layer alone.
        var noun = ""

        /// What a layer that cannot be read costs. It follows the sentence
        /// "<path> cannot be read", and it is empty when the component
        /// says no more than that.
        var unreadableCost = ""

        /// What a person does beyond the `chmod` command. It follows the
        /// command and the path, and it is empty when the command is the
        /// whole fix.
        var unreadableFixHint = ""
    }

    /// The finding of one layer: whether the directory is on disk, whether
    /// it can be read, and, when the component asks for it, whether it can
    /// be written.
    ///
    /// - Parameters:
    ///   - layer: The layer to check.
    ///   - wording: The words the component says about its own layers.
    ///   - category: The group the finding belongs to.
    ///   - requiresWrite: Whether the component writes to its layers, and
    ///     so needs the directory writable as well as readable.
    /// - Returns: The finding of that layer.
    static func check(
        of layer: DotfolderStack.Layer, wording: Wording, category: String, requiresWrite: Bool
    ) -> HealthCheck {
        let name = self.name(of: layer, noun: wording.noun)
        let path = layer.root.path
        switch ReadableDirectoryState.of(layer.root) {
        case .missing:
            return .ok(
                name: name, message: "\(path) is not on disk, and \(wording.missingReason)",
                category: category)
        case .unreadable:
            return .error(
                name: name, message: "\(path) cannot be read\(wording.unreadableCost)",
                fix: "\(ReadableDirectoryState.readFix) \(path)\(wording.unreadableFixHint)",
                category: category)
        case .readable:
            break
        }
        guard requiresWrite else {
            return .ok(name: name, message: "\(path) can be read", category: category)
        }
        guard FileManager.default.isWritableFile(atPath: path) else {
            return .warning(
                name: name, message: "\(path) cannot be written",
                fix: "\(writeFix) \(path)", category: category)
        }
        return .ok(
            name: name, message: "\(path) can be read and written", category: category)
    }

    /// What one layer's finding is called: the layer's own name, under the
    /// noun of the stack it belongs to.
    ///
    /// - Parameters:
    ///   - layer: The layer the finding reports.
    ///   - noun: The noun that names the stack, or the empty string.
    /// - Returns: The name of the finding.
    private static func name(of layer: DotfolderStack.Layer, noun: String) -> String {
        let source = ConfigurationLayerName(layer.source).rawValue
        guard !noun.isEmpty else {
            return "the \(source) layer"
        }
        return "the \(noun) \(source) layer"
    }
}
