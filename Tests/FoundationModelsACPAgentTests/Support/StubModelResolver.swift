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

    /// The gate that holds the answer of each reference in
    /// ``silentReferences``. The test opens it after the doctor returned.
    let lateAnswers = LateAnswerGate()

    /// Answers one lookup from ``namedLookups``, ``lookup`` and
    /// ``silentReferences``.
    ///
    /// - Parameter reference: The model reference to look up.
    /// - Returns: The scripted answer, or, when the reference is in
    ///   ``silentReferences``, an answer that comes only after the test
    ///   opens ``lateAnswers``. A doctor whose timeout works reports
    ///   ``ModelLookup/noAnswer`` before that, and drops the late answer.
    func lookUp(_ reference: ModelRef) async -> ModelLookup {
        let text = reference.stringValue
        if silentReferences.contains(text) {
            await lateAnswers.wait()
            return .found(downloadBytes: 0)
        }
        return namedLookups[text] ?? lookup
    }
}
