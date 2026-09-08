---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2166hs5f3yqahd08ek1wht3
  text: |-
    ### Correction — 2026-09-08. The VLM reading was wrong.

    This card said the model hangs because it is a vision-language model
    driven through the text path, and that a change of quantisation "does
    not answer this". **Both statements are wrong, and I measured them
    rather than inferring this time.**

    **Measured:** `acp-agent run "say hello"` with the standard slot pinned
    to `mlx-community/Qwen3.8-27B-mxfp4` wrote to stdout:

    ```
    Hello! 👋 How can I help you today?
    ```

    Real tokens, no stall entry. The same command on
    `mlx-community/Qwen3.8-27B-4bit` makes no token and hangs.

    **So the architecture is not the cause.** Both builds are
    `Qwen3_5ForConditionalGeneration` with `language_model_only: False` and
    a full vision tower. Only the quantisation differs:

    | build | quantisation | result |
    |---|---|---|
    | `-4bit` | affine, group_size 64 | hangs, zero tokens, 52 minutes in flight |
    | `-mxfp4` | mxfp4, group_size 32 | generates |

    **The family already runs the working build.** The `-4bit` pin in this
    package is the only place that names it:

    - `FoundationModelsMultitool` — `Sources/MultitoolCLI/CLIRunner.swift:410`,
      `generationModel: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"`.
    - `FoundationModelsRouter` — `Tests/.../JointFitTests.swift:835`,
      `multitoolGeneration: ModelRef = "org/Qwen3.8-27B-mxfp4"`.
    - `FoundationModelsRouter` — `Tests/.../CompactionEvalTiers.swift:197`
      carries real eval numbers "for Qwen3.8-27B (the standard model)".
    - `FoundationModelsRouter` — `Sources/.../Sizing/RepoMetadata.swift:283`
      reads the nested `text_config`, so a repo of this shape sizes
      correctly.

    So `^k4rq6ab` chose `-4bit` when the rest of the family had settled on
    `-mxfp4`, and nothing ever drove the `-4bit` build until today.

    ### What this card now asks

    1. Set `ProfileConfiguration.defaultStandard` to
       `mlx-community/Qwen3.8-27B-mxfp4`, and say in the doc comment that
       the family pins this build and where.
    2. Keep the guard. A generation that makes no token must be refused or
       reported, and never hang for 52 minutes. That stands whatever the
       default is, and it is what made this cost a day.

    The "support the vision-language path" option is dropped. The text path
    drives this model correctly at the mxfp4 quantisation.
  timestamp: 2026-09-08T18:58:59.493868+00:00
- actor: claude-code
  id: 01m218x1f1rwbzgksbv4gf1zgd
  text: |
    ### Where the guard belongs, and why it belongs here

    I looked for the honest owner before I wrote code.

    Router already emits `SessionEvent.generationStalled(GenerationStall)`,
    and `RoutedSession.streamEvents(to:maxTokens:)` states in its own doc
    comment that the event travels on the turn stream, "on each interval
    without a fragment". That is the stream `PromptTurn.drive` already
    consumes. So this package sees the stall as it happens, and no change
    in Router is necessary for a run-time guard.

    `streamEvents` also states: "Abandoning this stream cancels the turn."
    So leaving the drive loop is the sanctioned way to stop the generation.
    The guard needs no `cancelCurrentTurn()` call, and `drive` keeps its
    one parameter, which is what lets the tests drive it with a synthetic
    stream.

    `EventProjection` already tracked `sawOutput` for the `_no_output` stop
    reason of `^pez780d`. It is now `private(set)`, so the drive loop reads
    it beside the stall report. That is the second half of the guard, and
    it is what stops a slow tool from reading as a hung model.

    The model name comes from
    `ConfigOptions.handle(for: entry.selectedSlot, of: residentProfile)`,
    the same string `/status` shows. `PromptTurn` carries it, so the log
    line names the model.

    ### What this package cannot do

    A refusal at RESOLUTION time — before a turn starts — needs the loader,
    and the loader is Router's. This package receives an already resident
    `LanguageModelProfile` and sees the model only through the turn's event
    stream. So the run-time guard is the honest answer here, and a
    resolution-time refusal needs its own card on
    `FoundationModelsRouter`, discussed first. I edited no sibling package.

    ### What I did not do

    I did not re-run the tier-4 eval. It hangs for a separate reason, which
    `^ec8hn3z` tracks.
  timestamp: 2026-09-08T19:46:13.601052+00:00
- actor: claude-code
  id: 01m218x8dn0wfsr6ynxg7xe2t7
  text: |
    ### implement — changed
    - evidence: 7 files. Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift (the `_stalled` stop reason, the 120 s bound, `endsTurn`, the report, the `modelName` field and the wiring), Sources/FoundationModelsACPAgent/Agent/EventProjection.swift (`sawOutput` is `private(set)`), Tests/FoundationModelsACPAgentTests/PromptTurnTests.swift (four new tests and the totality test), Tests/FoundationModelsACPAgentTests/Support/ProjectionTestSupport.swift, Tests/FoundationModelsACPAgentTests/EventProjectionTests.swift, plan.md (§8.2 and §8.4), and the standard default of AgentConfiguration.swift that the working tree already carried.
    - `swift build` clean. Root `swift test`: 493 tests in 51 suites passed, with the one known issue at HarnessSmokeTests.swift:239. The count was 489 before; the four new tests make 493.
    - `swift build --package-path IntegrationTests --build-tests` is clean too, so the tier-4 target still compiles with the new `modelName` field.
    - next: review.
  timestamp: 2026-09-08T19:46:20.725870+00:00
- actor: claude-code
  id: 01m219e4hbk3gedqc30dtymhjz
  text: |
    ### review — clean

    - scope: `review sha HEAD~1..HEAD` (commit b80a57a), this repository only
    - evidence: 14 validator runs on 9 files, 0 findings, 0 confirmed, 0 refuted, 0 failed
    - not reviewed: `.kanban/` files by the ignore rule, `cli-plan.md` and `plan.md` because no validator matches a Markdown file
    - no prior `## Review Findings` section is open on this card
    - next: the card moves to Done. The one open acceptance item, the tier-4 eval samples, is the work of `^ec8hn3z` and not of this card.
  timestamp: 2026-09-08T19:55:33.803568+00:00
- actor: claude-code
  id: 01m219ep5nn6w3m83bdvndn9xm
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — the default moved to `mxfp4` in five places, and the stall guard was built in `PromptTurn`. Router already emits `SessionEvent.generationStalled` on the stream the turn consumes, so no sibling change was necessary.
    - test: green — swift build clean; root swift test 493 tests in 51 suites, one known issue (489 before, four new tests); the nested package builds clean
    - commit: b80a57a — 15 files
    - review: clean — 14 validator runs on 9 files, 0 findings
    - the card is in done

    The one unchecked item is the tier-4 eval criterion. `^ec8hn3z` holds it,
    because the eval hangs for a separate reason: `mxfp4` answers through
    `acp-agent run`, with the whole `searchTools` to `runCode` to `wait`
    chain, and it makes no fragment under the eval harness.

    A refusal at RESOLUTION time is still open, and it is Router's: this
    package receives a profile that is already resident. That needs a card
    on `FoundationModelsRouter`, discussed first.
  timestamp: 2026-09-08T19:55:51.861332+00:00
position_column: done
position_ordinal: bf80
title: The shipped standard default names the 4bit build, which does not generate
---
### What

The shipped standard default named `mlx-community/Qwen3.8-27B-4bit`,
set by `^k4rq6ab`. That build does not generate: a prompt turn makes no
token, makes no tool call, and never ends.

The first reading of this card said the cause was the vision-language
architecture. That reading was wrong, and the comment of 2026-09-08
corrects it with measurements. Both builds are
`Qwen3_5ForConditionalGeneration` with `language_model_only: false`.
Only the quantisation differs, and only the `4bit` build hangs.

### The measured evidence

| build | quantisation | result |
|---|---|---|
| `-4bit` | affine, group_size 64 | no token, 3120 s in flight, no end |
| `-mxfp4` | mxfp4, group_size 32 | answers, `stop end_turn`, exit 0 |

The family already pins `-mxfp4`: `FoundationModelsMultitool` at
`MultitoolCLI/CLIRunner.swift` (`generationModel`), and Router's
`JointFitTests` and its compaction eval tiers.

### What was done

- [x] Set `ProfileConfiguration.defaultStandard` to
      `mlx-community/Qwen3.8-27B-mxfp4`, with the evidence in the doc
      comment. The same change lands in the two unit tests, in the
      tier-4 eval pin, and in `cli-plan.md` §7 and §11.4.
- [x] Make the standard slot generate on the shipped default.
- [x] Add the guard: a generation that makes no token is ended and
      reported, and never hangs.

### The guard, as built

`PromptTurn.drive` reads each `generationStalled` report Router emits on
the turn's own event stream. The turn ends when two facts hold
together: the report names a model call that has made no fragment at
all for the whole `PromptTurn.stalledGenerationBound` of 120 seconds,
and the turn has made no observable output. The turn then leaves the
stream, which cancels Router's turn by that surface's own contract, and
stops with the `_stalled` extension stop reason. That reason maps to
exit code 1 through the §5.8 table. The log line names the model and
the report.

The two facts together keep the guard honest. A stall on a call that
already streamed is a slow decode; a stall on a fresh call raised while
a tool runs is a slow tool. Neither is a model that cannot generate.

### Acceptance Criteria

- [x] `acp-agent run "hello"` on the shipped default writes an answer.
- [x] A prompt turn on the shipped default reports a stop reason.
- [x] A model the loader cannot drive is ended and reported at run
      time, and the message names the model and the reason.
- [ ] The tier-4 eval samples report a stop reason and a token count
      that is not zero. The eval hangs for a separate reason, which
      `^ec8hn3z` tracks. It is not this card.

### Tests

- [x] Four tests in `PromptTurnTests` drive synthetic stall reports: a
      generation with no fragment past the bound ends as `_stalled`; a
      stall shorter than the bound does not end the turn; a stall past
      the bound after a fragment does not end the turn; a stall past
      the bound after a tool call does not end the turn.
- [x] The `_stalled` test drives a stream that never finishes, so only
      the guard can end the turn, and it states a one-minute time
      limit, so a hang fails it rather than running to the suite
      ceiling.

### What is left for another card

A refusal at RESOLUTION time — before a turn starts — belongs to
`FoundationModelsRouter`, which owns the loader. This package sees the
model only through the turn's event stream, so the run-time guard above
is what it can honestly do. A resolution-time refusal needs its own
card on Router, discussed first.

### What this card is NOT

It is not the `runCode` snippet question. `^95jyv07` recorded parse
failures, and those came from the stale eval pin
(`Qwen2.5-Coder-32B-Instruct-4bit`) and not from this agent.
