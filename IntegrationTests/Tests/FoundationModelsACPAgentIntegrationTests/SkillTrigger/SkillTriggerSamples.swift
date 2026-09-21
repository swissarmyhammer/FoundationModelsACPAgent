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
/// each one costs real seconds. Four samples — three for one skill and one
/// for the other — measure a missed load, and the whole suite then runs in
/// minutes.
///
/// **No sample measures an extra load.** A near-miss sample ("run the test
/// suite", which no skill covers) stood here until 2026-09-21. The use rule
/// of Skills `cbbcd37` made the model load a skill for it in two of three
/// runs. The owner of this work accepts that: an extra load costs one tool
/// call and the text of one skill, and a missed load loses the skill. A
/// sample with no bar is only time, thus it went.
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
    ]

    /// The samples whose task a skill covers.
    static var triggering: [SkillTriggerSample] {
        samples.filter { $0.expectedSkillID != nil }
    }
}
