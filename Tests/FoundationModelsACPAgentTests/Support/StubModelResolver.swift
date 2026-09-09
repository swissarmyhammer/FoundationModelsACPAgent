import Foundation
import FoundationModelsRouter

@testable import FoundationModelsACPAgent

/// A ``ModelResolver`` that answers from a script (cli-plan.md §5.12).
///
/// No test asks Hugging Face and no test reads the real model cache, so the
/// profile suite stays hermetic and fast. Each stored property is one
/// scripted answer.
struct StubModelResolver: ModelResolver {
    /// What one named reference answers. A reference this table does not
    /// name gets ``lookup``.
    var namedLookups: [String: ModelLookup] = [:]

    /// What a reference the table does not name answers.
    var lookup = ModelLookup.found(downloadBytes: 0)

    /// The references whose lookup does not answer before the doctor's
    /// timeout, which is what makes that timeout fire.
    var silentReferences: Set<String> = []

    /// Answers one lookup from ``namedLookups``, ``lookup`` and
    /// ``silentReferences``.
    ///
    /// - Parameter reference: The model reference to look up.
    /// - Returns: The scripted answer, or an answer that comes far too
    ///   late, when the reference is in ``silentReferences``.
    func lookUp(_ reference: ModelRef) async -> ModelLookup {
        let text = reference.stringValue
        if silentReferences.contains(text) {
            return await Self.answerTooLate()
        }
        return namedLookups[text] ?? lookup
    }

    /// Waits ``lateAnswerSeconds``, which is far past any timeout a test
    /// injects, and then answers.
    ///
    /// So a doctor whose timeout works reports ``ModelLookup/noAnswer``
    /// long before this returns, and a doctor whose timeout does not work
    /// waits the whole time and fails the elapsed-time assertion.
    ///
    /// The wait ends early when the doctor cancels the lookup. The answer
    /// that then comes back arrives after the timeout has already settled,
    /// so it is dropped — and no task is left suspended for ever.
    ///
    /// - Returns: The late answer.
    private static func answerTooLate() async -> ModelLookup {
        try? await Task.sleep(for: .seconds(lateAnswerSeconds))
        return .found(downloadBytes: 0)
    }

    /// How long a lookup of a silent reference waits, in seconds.
    private static let lateAnswerSeconds = 60.0
}
