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
