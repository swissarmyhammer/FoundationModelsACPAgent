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