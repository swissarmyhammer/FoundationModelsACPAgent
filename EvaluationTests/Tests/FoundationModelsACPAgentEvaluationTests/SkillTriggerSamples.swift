import Foundation

/// One prompt of the skill trigger evaluation, and the skill it must make
/// the model load.
///
/// A sample is a task, written the way a user writes one. It never names a
/// skill, an id, or the `skills` tool: the model must read the task, read the
/// catalog it was given, and choose. That choice is the whole measurement.
struct SkillTriggerSample: Sendable, Equatable {
    /// A short name for the report.
    let name: String

    /// The prompt of the turn.
    let prompt: String

    /// The id of the skill the model must load, or `nil` when no skill of
    /// the library fits the task and the model must load none.
    let expectedSkillID: String?
}

/// The dataset of the skill trigger evaluation.
///
/// The library the samples run against is `Tests/Fixtures/skills/` of the
/// root package: `fixture-explore` (understand code before a change) and
/// `fixture-release-notes` (write the release notes of a version). The
/// hidden skill of that library is not reachable, so no sample expects it.
///
/// **The dataset is small on purpose.** Each sample is one live turn, thus
/// each one costs real seconds. Five samples — three for one skill, one for
/// the other, and one near miss — measure the things that can go wrong, and
/// the whole suite then runs in minutes.
///
/// **The should-not-trigger sample matters as much as the others.** A
/// description that fires on every task is as wrong as one that never fires,
/// and only a near miss shows the difference: "run the tests" shares the
/// words of the work, and no skill covers it.
///
/// **One sample is written as a bug report, and not as a request.** The
/// other prompts say "work out how", "who calls", "what breaks" — the words
/// of the description of the skill. A SWE-bench problem statement says none
/// of them: it reports what broke, and the reader must decide that
/// understanding the code comes first. In the SWE-bench run of 2026-09-19
/// the model was given the catalog and loaded no skill, and `swebench-issue`
/// is that condition in one turn of a minute instead of one run of hours.
enum SkillTriggerDataset {
    /// The id of the skill for understanding code.
    static let exploreID = "fixture-explore"

    /// The id of the skill for release notes.
    static let releaseNotesID = "fixture-release-notes"

    /// Every sample, in report order.
    static let samples: [SkillTriggerSample] = [
        SkillTriggerSample(
            name: "understand-parser",
            prompt: """
                I need to change how the parser handles an empty file, but I do not know \
                this code. Work out how the parser reads a file and what a change to it \
                would touch, and tell me. Change nothing.
                """,
            expectedSkillID: exploreID),
        SkillTriggerSample(
            name: "who-calls",
            prompt: """
                Who calls the function `authenticate` in this project, and what breaks if \
                I change its arguments? Report what you find, and change nothing.
                """,
            expectedSkillID: exploreID),
        SkillTriggerSample(
            name: "release-notes",
            prompt: """
                Write the release notes of version 2.1 of this project. One line for each \
                change that a user sees.
                """,
            expectedSkillID: releaseNotesID),
        SkillTriggerSample(
            name: "swebench-issue",
            prompt: """
                `Model.objects.filter()` raises a TypeError when the queryset is empty and \
                the field is a nullable foreign key. It worked in 3.1 and it fails in 3.2. \
                Fix it.
                """,
            expectedSkillID: exploreID),
        SkillTriggerSample(
            name: "run-the-tests",
            prompt: """
                Run the test suite of this project and tell me the result. Change no file.
                """,
            expectedSkillID: nil),
    ]

    /// The samples whose task a skill covers.
    static var triggering: [SkillTriggerSample] {
        samples.filter { $0.expectedSkillID != nil }
    }

    /// The samples that no skill covers.
    static var nonTriggering: [SkillTriggerSample] {
        samples.filter { $0.expectedSkillID == nil }
    }
}
