---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ym9qd12391dt4sdj3hkmeb
  text: |-
    ### Model id check — all three resolve

    `curl -sI https://huggingface.co/<id>`, status line for each:

    | id | status line |
    |---|---|
    | `mlx-community/Qwen3.8-27B-4bit` | `HTTP/2 200` |
    | `mlx-community/Qwen3-4B-4bit` | `HTTP/2 200` |
    | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` | `HTTP/2 200` |

    The check discriminates. A control id that does not exist,
    `mlx-community/Qwen9.9-999B-4bit-NoSuchThing`, gives `HTTP/2 401` — thus a
    200 is not the answer for every path.

    The Hugging Face model API confirms each repository, and echoes the same id
    back, thus no redirect to a different name:

    - `mlx-community/Qwen3.8-27B-4bit` — 141331 downloads, last changed
      2026-08-14. cli-plan §11.4 doubted this id because "Qwen3.8" looked
      unusual, but the repository is real and much used.
    - `mlx-community/Qwen3-4B-4bit` — 17575 downloads, last changed 2025-04-28.
    - `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` — 14792 downloads, last
      changed 2025-06-06.

    No repository carries an MTP tag.

    The check is complete, thus the change can go on.
  timestamp: 2026-09-07T19:07:40.321545+00:00
- actor: claude-code
  id: 01m1ynaz1pv8wkt8tfc94831ke
  text: |-
    ### Notes for the next agent

    **The `/tdd` cycle, and how each new test was proved able to fail.**
    The empty-stack test failed immediately on the old defaults (three
    failures, one for each slot). The two guard tests pass on the old
    defaults as well as the new ones, thus a plain run proves nothing about
    them. To prove each one can fail, the defaults were made bad on purpose,
    one shape at a time, and then put back:

    | the bad default | the assertion that failed |
    |---|---|
    | `mlx-community/Qwen3-30B-A3B-MTP-4bit` | the MTP marker |
    | `mlx-community/Qwen3-30B-A3B-mtp-4bit` | the MTP marker, lower case |
    | `a flash model with no owner` | the part count, and the space |
    | `mlx-community/` | the empty part |

    Each assertion of the three tests is thus measured, not assumed.

    **The MTP match ignores case.** The card names the substring `-MTP-`,
    and the marker is usually upper case. But the case is the publisher's
    choice, not a rule, thus the test uses a case-insensitive match. A
    lower-case `-mtp-` names the same draft head, and the table above shows
    the test catches it.

    **Two doc comments outside the card became false, and were corrected.**
    `PythonCLIEvaluation.swift` records a 2026-09-02 measurement and named
    Qwen2.5-14B-Instruct as "the in-code default". After this change that
    statement is wrong. The text now says "the in-code default of that
    date", which keeps the historical record true. The same file's
    `evalSampleIdleCeilingSeconds` comment said "on the default 14B model";
    it now says "on the 14B model that was then the default". No code in
    that file changed, and the nested IntegrationTests suite was not run.

    **One doc claim was removed, not moved.** The old `ProfileConfiguration`
    comment said the defaults were "the same profile Router's README
    documents". That is no longer true, thus the sentence is gone.

    **`ProfileResolutionTests` needed no fixture change.** Its fixtures use
    `org/one`, `org/standard` and the `stub/*` refs; none of them pins a
    builtin default id. The suite passes unchanged. `StubProfileFixtures`
    is the same: it resolves `stub/standard`, `stub/flash` and
    `stub/embedding`.

    **Only one test pinned an old id.** `BuiltinCommandsTests` holds
    `defaultStandardModel`, which the `/status` and `/compact` assertions
    read. Its value moved to the new standard id. The literal stayed a
    literal: a comparison against the production constant would assert
    nothing about which id the default is.

    **A first `swift test` run reported "2 issues (including 1 known
    issue)", but the four runs after it, and every run after the change, all
    report exactly 1 known issue and exit 0. The cause was not found. If a
    later run shows a second issue, this is the first record of it.**
  timestamp: 2026-09-07T19:25:49.494850+00:00
- actor: claude-code
  id: 01m1ynb7hqhz965q0s6ktas78p
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift (the three statics, the 32 GB doc comment, the MTP note), Sources/FoundationModelsACPAgent/RoutedACPAgent.swift (16 GB to 32 GB), Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift (three new tests, plus their named constants), Tests/FoundationModelsACPAgentTests/BuiltinCommandsTests.swift (the pinned standard id), IntegrationTests/Tests/FoundationModelsACPAgentIntegrationTests/Evaluations/PythonCLIEvaluation.swift (two doc comments the change made false).
    - id check: `curl -sI https://huggingface.co/<id>` gave `HTTP/2 200` for all three ids. A control id that does not exist gave `HTTP/2 401`, thus the check discriminates.
    - `swift build`: Build complete, no source warning. The one line, `missing creator for mutated node: ... mlx-swift_Cmlx.bundle`, comes from the build system and is present at the baseline too.
    - `swift test`: 440 tests in 46 suites passed, with exactly 1 known issue, the `withKnownIssue` at HarnessSmokeTests.swift:239. Four runs, all the same. The baseline was 437 tests in 46 suites; the three new tests are the difference.
    - The nested IntegrationTests suite was NOT run, as the task instructed.
    - next: /review
  timestamp: 2026-09-07T19:25:58.199274+00:00
- actor: claude-code
  id: 01m1ynxxkef7ad9y00g87brgd7
  text: |
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (the commit `4e9a12d`), 5 files, engine findings 0
    - evidence: 2 findings — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:182`, `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:404`
    - confirmed: the three new ids are in the defaults; the three new tests run over all three slots; no code keeps an old id or the 16 GB figure; the case-insensitive MTP match does not reject an id it must accept
    - next: add a test for the `flash` and `embedding` overrides, and make the MTP check catch an id that ends with `-MTP`
  timestamp: 2026-09-07T19:36:10.606242+00:00
- actor: claude-code
  id: 01m1ynyrzf76m7gnbe29segtvy
  text: |
    ### finish iteration 1 — findings

    - implement: changed — 5 files. The three `ProfileConfiguration` statics, the 16 GB to 32 GB figure in `Configuration/AgentConfiguration.swift` and `RoutedACPAgent.swift`, three new tests in `ConfigurationLoaderTests.swift`, the one test in `BuiltinCommandsTests.swift` that pinned an old id, and two doc comments in `IntegrationTests/.../Evaluations/PythonCLIEvaluation.swift` that the change made false.
    - id check, done before any edit: `curl -sI https://huggingface.co/<id>` gave `HTTP/2 200` for `mlx-community/Qwen3.8-27B-4bit`, `mlx-community/Qwen3-4B-4bit` and `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`. A control id that does not exist gave `HTTP/2 401`, so a 200 is not the answer for every path. The id that cli-plan §11.4 doubted is real.
    - test: `swift test` — 440 tests in 46 suites passed with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`, four runs identical. The baseline was 437. `swift build` gave no source warning.
    - commit: `4e9a12d` `feat(config): make the Qwen3 models the defaults, and set a 32 GB floor`
    - review: findings — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:182`, `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:404`

    Both findings come from the card's own acceptance criteria, and the engine found nothing of its own.

    The review also answered two questions and found nothing wrong: no other place in the repository pins an old id or the 16 GB figure, because `cli-plan.md:412` states in writing that this plan does not edit `plan.md` or `README.md`; and `PythonCLIEvaluation.swift:69` keeps `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` on purpose, because it is the pinned evaluation model and not a default.
  timestamp: 2026-09-07T19:36:38.639936+00:00
- actor: claude-code
  id: 01m1yppvw896d5c6kcyvczxacx
  text: |
    ### Iteration 2 — the two review findings, and how each new assertion was proved able to fail

    Both findings are worked. One file changed:
    `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`.
    No file in `Sources/` changed, and `git diff -- Sources/` is empty.

    **Finding 2, the MTP marker.** The cause was one constant that carried a
    hyphen on each side. The cause is now gone from the whole file: the
    marker is `-MTP` and it stands one time, and the middle-of-id shape is
    derived from it —
    `multiTokenPredictionInfixMarker = "\(multiTokenPredictionMarker)\(modelIdentifierWordSeparator)"`.
    The check moved into one function, `namesMultiTokenPredictionRepository`,
    which reads the marker in the middle of an id and at the end of it. The
    match still ignores case, which the review confirmed is right.

    The defaults test now calls that function. That test alone still cannot
    fail on a correct default, because no default holds the marker, thus a
    second test stands beside it: `theMTPCheckReadsTheMarkerInTheMiddleAndAtTheEnd`
    runs the check over 7 ids and asserts the answer for each. Four hold the
    marker, in the middle and at the end, in upper case and in lower case.
    Three do not: two builtin defaults, and `mlx-community/Qwen3-mtprime-4bit`,
    which holds a bare `mtp` inside a word and which the check must accept.

    **Finding 1, the override.** `eachProfileSlotInTheProjectConfigWinsOverItsDefault`
    writes `standard`, `flash` and `embedding` in the project `config.yaml`
    and reads all three back. It asserts twice for each slot: the value
    equals the configured id, AND the value differs from the default. The
    second assertion is what shows the default LOSES; without it the first
    would hold if a configured id happened to equal a default.

    **The falsification of each new assertion.** The MTP work ran a real
    red-green cycle: the check was written with the middle-of-id match
    alone, and the two end-of-id rows failed at once. The override test
    guards behavior that already stands, thus the decoder was made bad on
    purpose, one slot at a time, and then put back.

    | what was made bad | the message |
    |---|---|
    | the check reads the middle of an id only | `theMTPCheckReadsTheMarkerInTheMiddleAndAtTheEnd(identifier:namesADraftHead:) recorded an issue with 2 arguments identifier → "mlx-community/Qwen3.5-9B-MTP", namesADraftHead → true at ConfigurationLoaderTests.swift:158:9: Expectation failed: Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead` |
    | the same, the lower-case row | the same message, `identifier → "mlx-community/Qwen3.5-9B-mtp"` |
    | the check reads a bare `mtp` | `... identifier → "mlx-community/Qwen3-mtprime-4bit", namesADraftHead → false ... Expectation failed: Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead` |
    | `flash` ignores the configured value | `eachProfileSlotInTheProjectConfigWinsOverItsDefault() recorded an issue at ConfigurationLoaderTests.swift:510:9: Expectation failed: profile.flash.map(\.stringValue) == [Self.configuredFlashModel]` and at `:513:9: Expectation failed: profile.flash != defaults.flash` |
    | `embedding` ignores the configured value | `... at ConfigurationLoaderTests.swift:511:9: Expectation failed: profile.embedding.map(\.stringValue) == [Self.configuredEmbeddingModel]` and at `:514:9: Expectation failed: profile.embedding != defaults.embedding` |
    | `standard` ignores the configured value | `... at ConfigurationLoaderTests.swift:509:9: Expectation failed: profile.standard.map(\.stringValue) == [Self.configuredStandardModel]` and at `:512:9: Expectation failed: profile.standard != defaults.standard`, beside `profileAndCompactionSectionsDecode() ... at :479:9` |

    The third row is the answer to "do not widen it so far that it rejects
    an id it should accept". A check that reads a bare `mtp` is caught by
    the test, thus the accept side is measured and not assumed.

    The `standard` row was not asked for. It was made because the other two
    slots were measured, and a slot that is not measured is a slot nobody
    knows about. Note that it fails the older test as well, which shows the
    two tests do not overlap wrongly: the older one reads the `standard`
    slot, and the new one reads all three.

    **A defect found beside this work, and where it now lives.** One full
    `swift test` run of five reported a second issue:

    ```
    Test aFirstInterruptCancelsTheTurnAndKeepsTheTextThatArrived()
    recorded an issue at InterruptTests.swift:140:9:
    Expectation failed: try capture.text() == Self.arrivedText
    ```

    This is the same shape the comment above records as "the cause was not
    found". The cause is a race: the test scripts a text delta and then an
    interrupt, and nothing puts the delta first, thus a busy machine can let
    the cancel win. Eight runs of `swift test --filter InterruptTests` alone
    each passed; the race opens only under the full run. It is not caused by
    this card, which changed one test file of the configuration suite. The
    card `^srre854` holds that work.
  timestamp: 2026-09-07T19:49:48.040154+00:00
- actor: claude-code
  id: 01m1ypq6xsqz7j62kzm7gaxztc
  text: |
    ### implement — changed
    - evidence: 1 file — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`. Both review findings are worked, and their checklist items are now `- [x]`. `git diff -- Sources/` is empty: no production file changed.
    - finding at `:182` (the MTP marker): the marker is now `-MTP`, stated one time, and the middle-of-id shape derives from it. One function, `namesMultiTokenPredictionRepository`, reads the marker in the middle of an id and at the end of it, without case. A new test, `theMTPCheckReadsTheMarkerInTheMiddleAndAtTheEnd`, runs the check over 7 ids: four hold the marker, and three do not, one of which holds a bare `mtp` inside a word.
    - finding at `:404` (the override): a new test, `eachProfileSlotInTheProjectConfigWinsOverItsDefault`, writes `standard`, `flash` and `embedding` in the project `config.yaml`, reads all three back, and asserts for each slot that the value equals the configured id and differs from the default.
    - falsification: 6 measurements, each with its message, in the comment above. The two end-of-id rows failed on the narrow check; a check that reads a bare `mtp` failed the accept row; and a decoder that ignores `flash`, `embedding` or `standard` failed the matching pair of assertions each time. The production file was put back after each one.
    - `swift build`: Build complete, no source warning. The one line, `missing creator for mutated node: ... mlx-swift_Cmlx.bundle`, comes from the build system and stands at the baseline too.
    - `swift test`: 442 tests in 46 suites, 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`. Three runs in a row give that result. The baseline was 440; the two new tests are the difference.
    - one run of five gave a second issue, an intermittent failure of `InterruptTests`. It is not caused by this card. The card `^srre854` holds that work.
    - the nested `IntegrationTests` suite was NOT run.
    - next: /review
  timestamp: 2026-09-07T19:49:59.353163+00:00
- actor: claude-code
  id: 01m1yq1kf52sbbtqkgdfndpp76
  text: |
    ### review — findings

    - evidence: 1 finding — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:171`. Scope `review sha HEAD~1..HEAD` (the commit `edd93d2`), the diffs only. The engine read 1 file, ran 7 validators, and gave 0 findings. The finding comes from the acceptance criteria of this card.
    - round 2: the two items of round 1 are answered, and the two boxes are correctly checked. The override test writes and reads all three profile slots. The MTP check now reads the marker at the end of an id.
    - the new item: the check needs a hyphen before the marker in each of its two shapes. Thus an id whose name starts with the marker, for example `mlx-community/MTP-Qwen3-30B-4bit`, goes through the check. This is the same cause as the item of round 1, in a shape that is still open.
    - next: read `MTP` as a word of the id — a hyphen or the owner separator before the word, and a hyphen or the end of the id after it. Add a row to `multiTokenPredictionExamples` for an id whose name starts with the marker. Then run `/review ^k4rq6ab` again.
  timestamp: 2026-09-07T19:55:39.877983+00:00
- actor: claude-code
  id: 01m1yq2ny1hgr7rnby6tfqjr79
  text: |
    ### finish iteration 2 — findings

    - implement: changed — 1 file, `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`. No production file changed. The MTP marker is now `-MTP`, written one time, and the check `namesMultiTokenPredictionRepository` reads it in the middle of an id and at the end of it, without regard to case. A table-driven test runs it over seven ids. The new test `eachProfileSlotInTheProjectConfigWinsOverItsDefault` writes all three slots in the project `config.yaml` and reads all three back, and asserts for each slot that the value equals the configured id and differs from the default.
    - falsification: six messages, one for each assertion of the override test, each measured by making the decoder bad for one slot and then putting it back. The MTP table needs no message: its four `true` rows fail against the old `-MTP-` marker, so it is a true regression test.
    - test: `swift test` — 442 tests in 46 suites with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`, three runs identical. The baseline was 440. `swift build` gave no source warning.
    - commit: `edd93d2` `test(config): read the MTP marker at the end of an id, and prove each profile slot`
    - review: findings — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:171`

    Both items of round 1 are confirmed answered, and the engine gave 0 findings of its own from 7 validators.

    The new finding is a third shape of the same cause. Round 1 named the marker in the middle only. Round 2 added the end of the id. Round 3 shows that an id whose name starts with the marker, such as `mlx-community/MTP-Qwen3-30B-4bit`, still goes through, because the character before the marker is the owner separator and not a hyphen. The correct fix reads `MTP` as a word of the id: a hyphen or the owner separator stands before the word, and a hyphen or the end of the id stands after it. That one rule covers each of the three shapes, so this iteration must remove the cause and not add a third special case.

    One thing found on the way, and not caused by this card: `aFirstInterruptCancelsTheTurnAndKeepsTheTextThatArrived` at `InterruptTests.swift:140` failed in one full run of five. The cause is a race — the case scripts a text delta and then an interrupt, and nothing orders the delta first. Card `^srre854` carries it. This is the intermittent second issue that earlier runs recorded without a cause.
  timestamp: 2026-09-07T19:56:15.169458+00:00
- actor: claude-code
  id: 01m1yqpe0t97v8canhjp84j97h
  text: |-
    ### Iteration 3 — one rule in place of the two shapes, and how each row was measured

    One file changed: `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`.
    `git diff -- Sources/` is empty; no production file changed.

    **The cause is gone, and no third special case stands.** The two shapes,
    and the constant `multiTokenPredictionInfixMarker` that carried a hyphen,
    are deleted. The marker is now the bare word `MTP`, written one time. One
    rule reads it: `MTP` is a word of the id. A word OPENS at the start of the
    id, after a hyphen, or after the owner separator `/`; a word CLOSES at the
    end of the id or before a hyphen. The match ignores case. The check calls
    that rule at each holding of the letters, from the start of the id to its
    end, thus no position is special.

    **Each position the one rule covers.** I went through them:

    | position | example | answer | why the one rule gives it |
    |---|---|---|---|
    | the start of the name | `mlx-community/MTP-Qwen3-30B-4bit` | `true` | the owner separator opens the word; a hyphen closes it |
    | the middle of the name | `mlx-community/Qwen3-30B-A3B-MTP-4bit` | `true` | a hyphen opens the word; a hyphen closes it |
    | the end of the id | `mlx-community/Qwen3.5-9B-MTP` | `true` | a hyphen opens the word; the end of the id closes it |
    | the whole name | `mlx-community/MTP` | `true` | the owner separator opens the word; the end of the id closes it |
    | an id with no owner separator | `MTP-Qwen3-4bit` | `true` | the start of the id opens the word; a hyphen closes it |

    Each of the five is one reading of one rule, not five branches. The start
    of the id opens a word for the same reason the end of the id closes one:
    a boundary of the string is a boundary of a word. The owner separator
    opens a word but does not close one, thus `mtp/Qwen3-4bit` — an owner
    whose whole name is `mtp` — names a publisher and not a draft head.

    **The accept side stays accept.** `Qwen3-mtprime-4bit` holds a bare `mtp`
    inside a word, `mtprime-4bit` starts with those letters, and
    `Qwen3-Xmtp-4bit` ends a word with them. All three get `false`.

    **The regression proof.** Six `true` rows are new, and each one FAILS
    against the check as it stood (the middle shape `-MTP-`, plus `-MTP` at
    the end with `.anchored` and `.backwards`). The check was put back to that
    shape on purpose, the messages were recorded, and the one rule was put
    back after:

    | new row | the message |
    |---|---|
    | `mlx-community/MTP-Qwen3-30B-4bit` | `theMTPCheckReadsTheMarkerAsAWordOfTheId(identifier:namesADraftHead:) recorded an issue with 2 arguments identifier → "mlx-community/MTP-Qwen3-30B-4bit", namesADraftHead → true at ConfigurationLoaderTests.swift:158:9: Expectation failed: Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead` |
    | `mlx-community/mtp-Qwen3-30B-4bit` | the same message, `identifier → "mlx-community/mtp-Qwen3-30B-4bit"` |
    | `mlx-community/MTP` | the same message, `identifier → "mlx-community/MTP"` |
    | `mlx-community/mtp` | the same message, `identifier → "mlx-community/mtp"` |
    | `MTP-Qwen3-4bit` | the same message, `identifier → "MTP-Qwen3-4bit"` |
    | `mtprime/MTP-4bit` | the same message, `identifier → "mtprime/MTP-4bit"` |

    **Each half of the one rule is necessary, and that is measured too.** A
    rule with one half removed is still one rule, thus a table that no half
    can break would prove nothing:

    | what was made bad | the row that caught it |
    |---|---|
    | the rule does not open the word | `identifier → "mlx-community/Qwen3-Xmtp-4bit", namesADraftHead → false ... Expectation failed: Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead` |
    | the rule does not close the word | the same message for `identifier → "mlx-community/Qwen3-mtprime-4bit"` AND for `identifier → "mlx-community/mtprime-4bit"` |
    | the check stops at the first holding of the letters | the same message for `identifier → "mtprime/MTP-4bit", namesADraftHead → true` |

    The last row is why `mtprime/MTP-4bit` is in the table: the letters stand
    twice, and only the second holding is a word. A check that reads the first
    holding alone answers `false` and fails.

    **The table now holds 15 rows**, 10 that name a draft head and 5 that do
    not, in upper case and in lower case.

    **The rules the review engine enforces were read before the edit.** Two
    Swift rules moved the name of the new helper: `fluent-usage` (a
    preposition attaches to the argument label) and `naming-clarity` (a noun
    precedes a weakly typed `String` parameter). The helper is thus
    `isAWord(_:ofIdentifier:)`, and it reads as an assertion at the call site.
    The `- Parameters:` entries name the internal parameter names, which
    `doc-parameter-naming` requires. The static table stays a `let`, which
    `immutability` requires.

    **One run of 19 reported a target failure.** That run tailed only its last
    line, thus the failing test was not captured. Eighteen runs after it, each
    one filtered for any issue that is not the known one, all reported 442
    tests in 46 suites with exactly 1 known issue. The shape matches the
    intermittent `InterruptTests` race that card `^srre854` carries, but the
    name was not measured, thus this note records what was seen and not more.
  timestamp: 2026-09-07T20:07:02.426590+00:00
- actor: claude-code
  id: 01m1yqpvj0xqev93m7qy9dbs91
  text: |-
    ### implement — changed

    - evidence: 1 file — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`. `git diff -- Sources/` is empty: no production file changed. The round-3 checklist item is now `- [x]`, and the card stays in `doing`.
    - the one rule: the two shapes and the hyphenated infix constant are DELETED, not kept beside a third case. The marker is the bare word `MTP`, stated one time. `namesMultiTokenPredictionRepository` reads each holding of the letters from the start of the id to its end, and `isAWord(_:ofIdentifier:)` answers whether that holding is a word: a word opens at the start of the id, after a hyphen, or after the owner separator `/`, and it closes at the end of the id or before a hyphen. The match ignores case.
    - the positions the one rule covers: the start of the name (`mlx-community/MTP-Qwen3-30B-4bit`), the middle (`.../Qwen3-30B-A3B-MTP-4bit`), the end of the id (`.../Qwen3.5-9B-MTP`), the whole name (`mlx-community/MTP`), and an id with no owner separator (`MTP-Qwen3-4bit`). The full table with the reason for each stands in the comment above.
    - the table: 15 rows, 10 `true` and 5 `false`, upper case and lower case. The accept rows are `Qwen3-mtprime-4bit` (a bare `mtp` inside a word), `mtprime-4bit` (a name that starts with those letters), and `Qwen3-Xmtp-4bit` (a word that ends with them), plus two builtin defaults.
    - regression proof: all SIX new `true` rows fail against the check as it stood. The six messages are recorded in the comment above, each one measured by putting the two-shape check back and then putting the one rule back.
    - the rule is not over-wide, and that is measured: a rule that does not open the word fails on `Qwen3-Xmtp-4bit`; a rule that does not close the word fails on `Qwen3-mtprime-4bit` and `mtprime-4bit`; a check that stops at the first holding fails on `mtprime/MTP-4bit`.
    - `swift build`: Build complete, no source warning. The one line, `missing creator for mutated node: ... mlx-swift_Cmlx.bundle`, comes from the build system and stands at the baseline too.
    - `swift test`: 442 tests in 46 suites, 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`. This equals the baseline the card names; a parameterized case adds table rows and not test counts.
    - 19 full runs. 18 gave that result. 1 reported a target failure whose test name was not captured, because that run read only its last line. The shape matches the known `InterruptTests` race on card `^srre854`. Reported as an exception, not fixed here.
    - the nested `IntegrationTests` suite was NOT run.
    - next: /review
  timestamp: 2026-09-07T20:07:16.288133+00:00
- actor: claude-code
  id: 01m1yr1s1y0gncjhf494av6h79
  text: |
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (the commit `9e8cd9a`), the diffs only. The engine read 1 file and gave 0 findings.
    - evidence: 1 finding — Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:266
    - The cause of round 2 is removed. One rule, `isAWord`, decides every position. The two position shapes and the constant that carried a hyphen are gone.
    - No counterexample was found. A run over the 15 rows of the table, and over nine more ids, gives the correct answer each time.
    - The owner half is right: `mtp/Qwen3-30B-4bit` gives `false`, and `mlx-community/MTP` gives `true`.
    - The three items of the two earlier rounds are answered, and the three boxes stay checked.
    - next: add a `false` row for `mtp/Qwen3-30B-4bit` to `multiTokenPredictionExamples`, then review again.
  timestamp: 2026-09-07T20:13:14.174127+00:00
- actor: claude-code
  id: 01m1yr2tfj0ykrzam10nr2b345
  text: |
    ### finish iteration 3 — findings

    - implement: changed — 1 file, `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`. `git diff -- Sources/` is empty. The two position shapes and the constant that carried a hyphen are deleted. One rule stands in their place: `MTP` is a word of the id, opened by the start of the id, a hyphen, or the owner separator, and closed by the end of the id or a hyphen. The match ignores case, and a loop applies the rule at each holding of the letters. The table grew to 15 rows, 10 true and 5 false.
    - falsification: each of the six new true rows fails against the old check. Each half of the rule is measured as necessary: a rule with no opener fails on `Qwen3-Xmtp-4bit`; a rule with no closer fails on `Qwen3-mtprime-4bit` and `mtprime-4bit`; a check that stops at the first holding fails on `mtprime/MTP-4bit`.
    - test: `swift test` — 442 tests in 46 suites with 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`, in 18 of 19 runs. One run reported a target failure whose name the run did not capture; its shape matches the known `InterruptTests` race on card `^srre854`. `swift build` gave no source warning.
    - commit: `9e8cd9a` `test(config): read the MTP marker as a word, not at a position`
    - review: findings — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:266`

    The review confirmed that the cause is removed: one function decides every position, no branch reads a position, and the marker is written one time. It ran the rule over the 15 table rows and nine more ids, and it states that it can name no id the check gets wrong in either direction. The three earlier findings stay answered.

    The new finding is small and it is not a fourth shape of the old cause. The rule is correct; the table does not prove one half of it. No row holds an id whose owner is exactly `mtp`, so a change that made the rule symmetrical would reject `mtp/Qwen3-30B-4bit`, which the check must accept, and all 15 rows would still pass.
  timestamp: 2026-09-07T20:13:48.402186+00:00
- actor: claude-code
  id: 01m1yrxscyy00cqphfvwr4depv
  text: |
    ### Iteration 4 — the owner rows, and the measurement that earns them

    One file changed:
    `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`.
    `git diff -- Sources/` is empty, and `git diff -- IntegrationTests/` is
    empty. No production file changed, and no file of a family package changed.

    **What the finding asked for, and what the table now holds.** The finding
    says that no row proves the owner half of the rule. Two rows now prove it:

    | new row | answer | why the rule gives it |
    |---|---|---|
    | `mtp/Qwen3-30B-4bit` | `false` | the start of the id opens the word, but the owner separator does not close it |
    | `MTP/Qwen3-30B-4bit` | `false` | the same, in upper case |

    The finding named the first row. The review named the second row in its
    own text: "`mtp/Qwen3-30B-4bit` and `MTP/Qwen3-30B-4bit` give `false`".
    The task added it for the same reason. The check ignores case, thus each
    case of the owner must get the same answer, and one row alone measures
    one case alone.

    **The rule did not change.** The finding says in writing not to change
    it, because the review ran it over 24 ids and confirmed it correct in
    both directions. `namesMultiTokenPredictionRepository` and `isAWord` are
    the same as before this iteration. The diff holds two rows and one doc
    comment, and nothing else.

    **The measurement that earns the two rows.** The owner separator went
    into the closers, which makes the rule symmetrical:

    ```
            let closesAWord =
                range.upperBound == identifier.endIndex
                || modelIdentifierWordOpeners.contains(identifier[range.upperBound])
    ```

    That is the one-character change the finding describes. With it, the run
    gave exactly two issues, and they are exactly the two new rows:

    ```
    Test theMTPCheckReadsTheMarkerAsAWordOfTheId(identifier:namesADraftHead:)
    recorded an issue with 2 arguments identifier → "mtp/Qwen3-30B-4bit",
    namesADraftHead → false at ConfigurationLoaderTests.swift:158:9:
    Expectation failed:
    Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead

    Test theMTPCheckReadsTheMarkerAsAWordOfTheId(identifier:namesADraftHead:)
    recorded an issue with 2 arguments identifier → "MTP/Qwen3-30B-4bit",
    namesADraftHead → false at ConfigurationLoaderTests.swift:158:9:
    Expectation failed:
    Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead

    Test theMTPCheckReadsTheMarkerAsAWordOfTheId(identifier:namesADraftHead:)
    with 17 test cases failed after 0.001 seconds with 2 issues.
    ```

    Two issues from 17 rows. The other 15 rows passed, which is what the
    finding said would happen. Thus each new row is necessary, and neither
    one is a copy of a row that already stands. The rule then went back, and
    the 17 rows passed again.

    **The doc comment of the table is true again.** It said "The last five",
    and the table now holds seven `false` rows. The new text tells why the
    two owner rows stand, and it names the one-character change they catch.
    The engine rule `case-sensitivity-coverage` holds ONE row as enough for a
    case contract, thus the comment states in writing why two stand: the
    check ignores case, thus each case must get the same answer.

    **No other site reads the token.** The rule `invariant-propagation` asks
    that each site which reads the same token gets the same treatment. A
    search of every `.swift` file for `mtp`, without regard to case, gives
    two files: this test file, and a doc comment in
    `Sources/.../Configuration/AgentConfiguration.swift`. The check is the
    one consumer of the token, and the table is the one data site. There is
    no sibling site, thus there is nothing to propagate.

    **The rules of the review engine were read before the edit.** The dump
    gave 60 rules over 7 validators for a Swift file. The rules that bear on
    the edit and their answers: the table stays a `private static let` with
    its `[(String, Bool)]` annotation (`immutability`, `idioms`,
    `access-control`); the comment is a `///` doc comment
    (`no-commented-code`); the two string literals need no name, because
    `no_magic_numbers` reads a numeric literal only and `data-driven` "never
    reports a constant for want of a name"; the two rows are per-case data,
    which the `reuse` carve-out protects word for word; and no rule of the
    set states a count rule, a staleness rule, or a language rule for prose.

    **Test results.** `swift build` gave Build complete and no source
    warning. The one line, `missing creator for mutated node: ...
    mlx-swift_Cmlx.bundle`, comes from the build system and stands at the
    baseline too. `swift test` gave 442 tests in 46 suites with exactly 1
    known issue, the `withKnownIssue` at `HarnessSmokeTests.swift:239`, in
    four runs of four. This equals the baseline the card names: a
    parameterised case adds a table row and not a test. The nested
    `IntegrationTests` suite was NOT run. `InterruptTests` did not fail in
    any of the four runs.
  timestamp: 2026-09-07T20:28:32.030475+00:00
- actor: claude-code
  id: 01m1yry5q6bdrtk13cdfjkfg03
  text: |
    ### implement — changed

    - evidence: 1 file — `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift`. `git diff -- Sources/` and `git diff -- IntegrationTests/` are both empty: no production file changed, and no file of a family package changed. The round-4 checklist item is now `- [x]`, and the card stays in `doing`.
    - rows added: `("mtp/Qwen3-30B-4bit", false)` and `("MTP/Qwen3-30B-4bit", false)`. The table now holds 17 rows, 10 `true` and 7 `false`.
    - the rule did not change. `namesMultiTokenPredictionRepository` and `isAWord` are the same as before, which the finding asks for in writing.
    - failure message, from the run with the owner separator put in the closers: `Test theMTPCheckReadsTheMarkerAsAWordOfTheId(identifier:namesADraftHead:) recorded an issue with 2 arguments identifier → "mtp/Qwen3-30B-4bit", namesADraftHead → false at ConfigurationLoaderTests.swift:158:9: Expectation failed: Self.namesMultiTokenPredictionRepository(identifier) == namesADraftHead`, and the same message for `identifier → "MTP/Qwen3-30B-4bit"`. The run ended `with 17 test cases failed after 0.001 seconds with 2 issues`.
    - exactly 2 issues from 17 rows. The other 15 rows passed, thus each new row earns its place and neither one repeats a row that stands. The rule went back after the measurement, and the 17 rows passed again.
    - doc comment: the count went from "The last five" to "The last seven", and the new text tells why the two owner rows stand and names the one-character change they catch.
    - `swift build`: Build complete, no source warning. The one line, `missing creator for mutated node: ... mlx-swift_Cmlx.bundle`, comes from the build system and stands at the baseline too.
    - `swift test`: 442 tests in 46 suites, 1 known issue, the `withKnownIssue` at `Tests/FoundationModelsACPAgentTests/Support/HarnessSmokeTests.swift:239`. Four runs of four give that result, which equals the baseline the card names. `InterruptTests` did not fail in any run.
    - the nested `IntegrationTests` suite was NOT run. No network request was made.
    - next: /review
  timestamp: 2026-09-07T20:28:44.646596+00:00
position_column: doing
position_ordinal: '80'
title: 'New default profile: Qwen3 models and a 32 GB memory floor'
---
## What

cli-plan.md §7. The builtin defaults of `AgentConfiguration` are what a
person with no `config.yaml` gets, and the present models are out of
date.

In `Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift`,
change the three `ProfileConfiguration` statics:

| Property | From | To |
|---|---|---|
| `defaultStandard` | `mlx-community/Qwen2.5-14B-Instruct-4bit` | `mlx-community/Qwen3.8-27B-4bit` |
| `defaultFlash` | `mlx-community/Qwen2.5-3B-Instruct-4bit` | `mlx-community/Qwen3-4B-4bit` |
| `defaultEmbedding` | `mlx-community/bge-small-en-v1.5-4bit` | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` |

Update the doc comment: the profile now needs **32 GB**, not 16 GB. A
27B model at 4 bits is about 15 GB on its own, and Router's `JointFit`
prices the whole trio against the budget.

**No MTP model is a default** (§7.1). Router calls the plain generate
path and never reads an MTP draft head, so an MTP repository would
download bytes that do nothing.

**Verify the three ids before the change lands.** cli-plan §11.4 admits
that `mlx-community/Qwen3.8-27B-4bit` was never checked, and "Qwen3.8"
matches no released Qwen naming.
`mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` **is** real —
`TierThreeFixture.userConfigYAML` already uses it — which makes the
other two conspicuous. **A wrong default breaks every first run**, and
the check that would catch it lives four hops downstream. Do the check
here.

- [x] `curl -sI https://huggingface.co/<id>` returns 200 for each of the
      three ids. Record the three results in a task comment.
- [x] If an id 404s, stop and ask before writing it in. Do not ship a
      default that cannot resolve.
- [x] Change the three model statics
- [x] Update the doc comments and the 16 GB figure
- [x] Update the tests that pin the old ids

## Acceptance Criteria

- [x] A task comment records a 200 for each of the three ids.
- [x] `AgentConfiguration()` gives the three new model references.
- [x] A `config.yaml` that names its own models still wins over each
      default.
- [x] No default names an MTP repository.
- [x] `swift build` and `swift test` pass with no warning.

## Tests

- [x] `ConfigurationLoaderTests`: the empty-stack case asserts the three
      new ids exactly.
- [x] A new test asserts that no default model reference holds the
      substring `-MTP-`, so a future edit cannot make one a default by
      accident.
- [x] A new test asserts each default id matches the shape
      `owner/name` — non-empty parts, no whitespace. This is the cheap
      half of the doctor's model check, available immediately.
- [x] `ProfileResolutionTests` still passes, with its fixtures updated.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-09-07 14:35)

> Scope: `review sha HEAD~1..HEAD` (the commit `4e9a12d`) — the diffs only.
> The engine read 5 files and gave 0 findings. The two items below come from
> the acceptance criteria of this card.

- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:404` `review/acceptance-criteria` — No test shows that a `config.yaml` `flash` value or `embedding` value wins over its default. The test `profileAndCompactionSectionsDecode` writes only a `standard` list, and it reads `flash` back as the default. Thus the criterion "A `config.yaml` that names its own models still wins over each default" is true for one slot of three. Add a test that writes all three slots in the project `config.yaml`, and that reads all three values back.
- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:182` `review/acceptance-criteria` — The marker `-MTP-` has a hyphen on each side. Thus an id that ends with `-MTP`, for example `mlx-community/Qwen3.5-9B-MTP`, goes through the check. The criterion "No default names an MTP repository" is thus not fully held. Also match the marker `-MTP` at the end of the id.

### What this pass agrees with

- The three tests hold the guarantees the card asks for. The empty-stack
  test asserts the three new ids exactly. The MTP test and the shape test
  each run over `standard + flash + embedding`, thus each default is
  examined.
- The shape test is correct. `split(omittingEmptySubsequences: false)`
  keeps an empty part, thus `owner/` and `/name` fail. The count of 2
  rejects `a/b/c`. The whitespace check reads the full id.
- The match that ignores case is correct. The case of the marker is the
  publisher's choice. The hyphen on each side keeps the match out of the
  middle of a word, thus the match does not reject an id it must accept.
- No place in the code keeps an old id or the 16 GB figure. `plan.md:191`
  keeps the 16 GB figure, but cli-plan.md §7.1 says in writing that this
  plan does not edit `plan.md` or `README.md`, and that §12 records the
  difference. `README.md` holds neither an old id nor a memory figure.
  `PythonCLIEvaluation.swift:69` keeps `Qwen2.5-Coder-32B-Instruct-4bit`
  on purpose: it is the pinned eval model, not a default.
- The two doc comments in `PythonCLIEvaluation.swift` are now true. They
  tell that the 14B model was the default on that date.

## Review Findings (2026-09-07 15:05)

> Scope: `review sha HEAD~1..HEAD` (the commit `edd93d2`) — the diffs only.
> The engine read 1 file and gave 0 findings. The item below comes from the
> acceptance criteria of this card.

- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:171` `review/acceptance-criteria` — `namesMultiTokenPredictionRepository` reads two shapes of the marker, and a hyphen stands before the marker in each shape. Thus an id whose name starts with the marker, for example `mlx-community/MTP-Qwen3-30B-4bit`, goes through the check: the character before the marker is the owner separator `/`, not a hyphen. The criterion "No default names an MTP repository" is thus not fully held. Round 1 named the end-of-id shape, and that shape is one example of this cause. Remove the cause: read `MTP` as a word of the id, where a hyphen or the owner separator stands before the word, and a hyphen or the end of the id stands after the word. Add a row to `multiTokenPredictionExamples` for an id whose name starts with the marker.

### The two items of round 1 are answered

- Item 1, the override test: answered. `eachProfileSlotInTheProjectConfigWinsOverItsDefault`
  writes all three slots in the project `config.yaml` and reads all three
  values back. Each slot gets two assertions: the value is equal to the
  configured id, and the value is different from the default. The equality
  is against a list of one item, thus the test also shows that the
  configured list replaces the default list, and does not add to it. The
  box is correctly checked.
- Item 2, the marker at the end of an id: answered for the shape the item
  named. The check now reads `-MTP` at the end of an id, with `.anchored`
  and `.backwards`, which is the correct way to anchor a match at the end
  of a string. The box is correctly checked. The new item above names a
  different shape of the same cause.

### What this pass agrees with

- The widened check rejects no id it must accept. The middle shape needs
  `-MTP-`, and the end shape needs the id to end with `-MTP`. A bare `mtp`
  inside a word matches neither. `mlx-community/Qwen3-mtprime-4bit` is in
  the table and gets `false`.
- The table kills each branch of the check. Rows 1 and 2 pass only through
  the middle branch, and rows 3 and 4 pass only through the end branch.
  Thus a deletion of either branch makes the test fail. This is a stronger
  proof than a falsification message.
- The six falsification messages account for the six assertions of the
  override test. The MTP table test needs no message: its four `true` rows
  fail against the old `-MTP-` marker, thus the test is a true regression
  test for the item of round 1.
- The guard is in the right home. The card asks in writing for a test, and
  the thing the guard reads is a compile-time constant. No code reads the
  MTP shape at run time. A guard over a constant belongs in the suite,
  which is where a later edit meets it.

## Review Findings (2026-09-07 15:20)

> Scope: `review sha HEAD~1..HEAD` (the commit `9e8cd9a`) — the diffs only.
> The engine read 1 file and gave 0 findings. The item below comes from the
> acceptance criteria of this card.

- [x] `Tests/FoundationModelsACPAgentTests/ConfigurationLoaderTests.swift:266` `review/acceptance-criteria` — The five `false` rows of `multiTokenPredictionExamples` do not hold an id whose owner is exactly `mtp`, for example `mtp/Qwen3-30B-4bit`. The doc comment of `namesMultiTokenPredictionRepository` promises this answer in writing: "The owner separator opens a word but does not close one, thus an owner whose whole name is `mtp` names a publisher, not a draft head." No row of the table proves it. A run of the rule with the owner separator put in the closers, which makes the rule symmetrical, gives `true` for `mtp/Qwen3-30B-4bit` — the check then rejects a default it must accept — and all 15 rows still pass. Thus one character can break the promise, and the table stays green. Add a `false` row for `mtp/Qwen3-30B-4bit`.

### The three items of the two earlier rounds are answered

- Round 1, item 1, the override test: answered.
  `eachProfileSlotInTheProjectConfigWinsOverItsDefault` is in the file at
  line 545. It writes all three slots and reads all three values back. The
  box is correctly checked.
- Round 1, item 2, the marker at the end of an id: answered. The word rule
  closes a word at the end of the id, thus the end position needs no
  special case. The rows `mlx-community/Qwen3.5-9B-MTP` and
  `mlx-community/Qwen3.5-9B-mtp` prove it. The box is correctly checked.
- Round 2, the marker at the start of the name: answered. The owner
  separator opens a word, thus `mlx-community/MTP-Qwen3-30B-4bit` gets
  `true`. The rows at lines 271 and 272 prove it. The box is correctly
  checked.

### What this pass agrees with

- The cause is removed, and this is a rule, not a third patch. One
  function, `isAWord`, decides every position. The two position shapes and
  the constant that carried a hyphen are gone. The marker is the bare word
  `MTP`, written one time at line 249. A word opens at the start of the id
  or after a character of `modelIdentifierWordOpeners`; a word closes at
  the end of the id or before a hyphen. No branch reads a position. The
  loop then applies the same rule at each holding of the letters, thus the
  rule is not tied to the first holding either. `mtprime/MTP-4bit` proves
  the loop: the first holding is not a word, and the second holding is.
- No counterexample was found. A run over the 15 rows of the table, and
  over nine more ids, gives the correct answer each time:
  `mtp/Qwen3-30B-4bit` and `MTP/Qwen3-30B-4bit` give `false`;
  `mtp/MTP-4bit`, `mtp`, `MTP` and `mlx-community/Qwen3-MTP` give `true`;
  `mlx-community/MTPQwen3` gives `false`; the empty id gives `false` and
  the loop always moves forward, thus it always stops.
- The owner half is right. An owner named `mtp` does not make the check
  fire, because the owner separator closes no word. A name that is exactly
  `MTP` makes the check fire, because the owner separator opens a word and
  the end of the id closes it. The rows at lines 273 and 274 prove the
  second half. The item above asks for a row that proves the first half.
- Each of the other four `false` rows is a right negative, and each kills
  a half of the rule. `Qwen3-mtprime-4bit` and `mtprime-4bit` kill a rule
  that does not close the word. `Qwen3-Xmtp-4bit` kills a rule that does
  not open the word. The two builtin defaults are ids the check reads
  every run.
