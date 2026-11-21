---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7yx710hyzq1467vnmjjqbr6
  text: |-
    Picked up (2026-11-21). Research before the first edit. BLOCKED: a question for the user. No file changed.

    Facts:
    - Router's `ProfileDefinition.init(from:)` (pin in `.build/checkouts/FoundationModelsRouter`) has code defaults for 4 keys: `decision` (`defaultDecisionCandidates`, the h2o-lightning-4b GGUF), `context` (`nil`, from the model), `decisionContext` (`defaultDecisionContext`, 16384) and `kvBits` (no key = fp16). It has NO default for `name`, `description`, `standard`, `flash` and `embedding`: a missing key is a `DecodingError`.
    - Today the merge over `large.yaml` (`BundledProfiles.baseKeys` in `ProfileFile.definition(of:name:path:)`) gives those 5 keys (`name` comes from the file name). Thus an empty file, or a file with only `kvBits: 8` or only `description:`, is valid today and has the models of `large`. The README documents this, and tests use it (for example `ProfileStoreTests` saves `description: mine\n`; `ProfileFileTests` decodes `kvBits: 8\n` and an empty file).

    The question (`standard` has no sensible default in code: any model there is "large as the default" again):
    1. `standard`: (a) a required key: a file with no `standard` is an error that names the file and the key (my recommendation); or (b) a code constant that names a model (which one?).
    2. `flash`: (a) default = the `standard` list, so the two slots share one model, as each bundled profile does now (my recommendation); or (b) a required key.
    3. `embedding`: (a) a code default `erjigit17/embeddinggemma-300m-ane-coreml`, the same in each bundled profile and not dependent on the size of the Mac, like Router's `defaultDecisionCandidates` (my recommendation); or (b) a required key.
    4. `description`: (a) default empty text (my recommendation); or (b) a required key.
    5. The place of the defaults: (a) one type in this repository, beside `ProfileFile` (for example `ProfileFile.Defaults`), that fills the missing keys before Router decodes; Router does not change (my recommendation); or (b) move the defaults into Router's `ProfileDefinition` (a change in the Router repository).

    With 1a, an empty file and a file with only `kvBits` become errors. The tests and README text that use such files change to name `standard`.
  timestamp: 2026-11-21T11:17:39.985260+00:00
- actor: claude-code
  id: 01m7yx73qvze1n0hcrjc94vhc0
  text: |-
    ### implement — stuck
    - evidence: no file changed. Router's `ProfileDefinition` has code defaults for `decision`, `context`, `decisionContext` and `kvBits`, but none for `standard`, `flash`, `embedding` and `description`; today those come only from the merge over `large.yaml`. A code default for `standard` must name a model, and that is the "large as the default" choice again.
    - next: the user answers the 5 questions in the comment above (recommended: 1a `standard` required, 2a `flash` = `standard`, 3a `embedding` code default, 4a `description` empty, 5a defaults in one type in this repository). Then implement with TDD, and after that add `kvBits: 8` to `large.yaml` (^wx4ewrs).
  timestamp: 2026-11-21T11:17:42.779771+00:00
- actor: claude-code
  id: 01m7yy34k42vt13wq3w3c7s82n
  text: |-
    User decision (2026-11-21), for the 5 questions of the implement step:
    - "have defaults, be consistent": each key of a profile has a code default, in the same style as the 4 that Router has today (decision, context, decisionContext, kvBits). Thus standard, flash, embedding and description also get code defaults. No key is required, and an empty profile file is valid.
    - "Router ProfileDefinition": the defaults go in Router's `ProfileDefinition`, not in this repository.
    - The request went to the session foundationmodelsrouter-f1 (proposals: flash = the standard list when absent; embedding = erjigit17/embeddinggemma-300m-ane-coreml; description = empty; standard = a model constant that Router names on its own terms, not "large"; kvBits absent = fp16; encode then decode gives the same definition).
    - Next in this repository, after the Router sha: remove the merge over large.yaml (BundledProfiles.baseKeys in ProfileFile), state the keys that differ from the Router defaults in each bundled file, add kvBits 8 to large.yaml, and update the docs and tests.
  timestamp: 2026-11-21T11:33:01.156894+00:00
- actor: claude-code
  id: 01m7z01rw6g3mt3xgjyb32afxf
  text: |-
    Implementation (2026-11-21), after the user decision: each key has a default in Router's `ProfileDefinition` (Router origin/main e221cbdd).

    Pin: `swift package update FoundationModelsRouter` gives Router e221cbd (`Package.resolved`, gitignored). Extras 49c6965 and Multitool d8863fb did not move. No llama.cpp clone in the root package.

    The defaults (all from Router, in one place: `ProfileDefinition`; this repository adds no default of its own):
    - `name`: required; the file name gives it.
    - `description`: `defaultDescription`, an empty text.
    - `standard`: `defaultStandardCandidates`, Qwen3.5-9B-4bit with the drafter Qwen3.5-9B-MTP-4bit (it fits the 16 GB floor).
    - `flash`: the `standard` list of the same profile.
    - `embedding`: `defaultEmbeddingCandidates`, erjigit17/embeddinggemma-300m-ane-coreml.
    - `decision`: `defaultDecisionCandidates` (h2o-lightning-4b GGUF); `context`: none (from the model); `decisionContext`: 16384; `kvBits`: no key, fp16.

    Code:
    - `ProfileFile.definition(of:name:path:)` decodes the keys of the file directly as Router's `ProfileDefinition` with `name` = the file name. The merge over `large.yaml` is removed. An unknown key, a wrong `name` and a bad value stay errors that name the file (the tests of these did not change and pass).
    - `BundledProfiles.baseKeys` is removed. `baseName` is now `largestName` (it is no longer a base); `defaultName` is still `large`.
    - The bundled files name only the keys that differ from the defaults: `description`, `standard` and `kvBits: 8` in each. `flash`, `embedding`, `decision` and `decisionContext` are removed, because they are equal to the defaults. My choice: `small.yaml` names its `standard` model, also though it is the default, so that the file shows its model (the header comment says so).
    - `large.yaml` has `kvBits: 8` (^wx4ewrs).
    - Texts: README (a table of the defaults; the `large` row names the 8-bit KV cache; `profiles show`), ARCHITECTURE.md (Profiles), the doc comments of `ProfileFile` and `BundledProfiles`, the help of `profiles show`, the `saveProfile` argument description of the `models` endpoint, and the `models` tool description. The `models` tool description also named the bundled profiles as "(large, small)"; it now says "(large, medium, small)".
    - `DocumentationSyncTests`: new test `readmeNamesEveryDefaultModelOfAProfileFile` (the README names each model of Router's defaults). It passed at the first run, because the README names those models already; it holds the README to a later change of a default. The repeated id closure is now one helper `modelIds(of:)`.

    TDD:
    - RED 1 (old code, new Router): `anEmptyFileHasTheDefaultsOfRouter`, `aFileWithOneKeyGetsTheDefaultsOfRouterForEachOtherKey` and `largeIsTheEightBitModelWithItsDrafterAndAnEightBitKVCache` failed.
    - RED 2 (`kvBits: 8` in `large.yaml`, merge still there): `noKVBitsGiveAnUnquantizedKVCache` and the new `theTextOfAnFP16ProfileDecodesBack` failed. This shows that they catch the inheritance from `large`.
    - GREEN (merge removed): ProfileFileTests 30 of 30 pass.

    Checks:
    - Tests that write a file with only `kvBits` or only `description` (`aFileWithKVBitsAloneIsValid`, `ProfileStoreTests` `description: mine`) still pass: Router gives each other key.
    - `DefaultProfileChoiceTests` use a fake fit source; `FitFallbackBudgetTests` assert "not `large`" and "the same router resolves its choice". Both still describe the right behavior and pass.

    IntegrationTests package: NOT BUILT. `swift build --package-path IntegrationTests --build-tests` made fresh checkouts in `IntegrationTests/.build`, and git started a submodule clone of `https://github.com/ggml-org/llama.cpp.git` into `llama-cpp-swift`. I stopped the build at once (the instruction says stop on a llama.cpp clone). Its pin of Router is still 95c2141. A person decides if the clone may run.
  timestamp: 2026-11-21T12:07:13.542972+00:00
- actor: claude-code
  id: 01m7z0h0p8dhs7wd8vffp6edzm
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/FoundationModelsACPAgent/Configuration/ProfileFile.swift, Sources/FoundationModelsACPAgent/Configuration/BundledProfiles.swift, Sources/FoundationModelsACPAgent/Resources/profiles/{large,medium,small}.yaml, Sources/FoundationModelsACPAgent/Models/ModelsGraph.swift, Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift, Sources/acp-agent/ProfilesCommand.swift, README.md, ARCHITECTURE.md, Tests/FoundationModelsACPAgentTests/{ProfileFileTests,DocumentationSyncTests,FitFallbackBudgetTests}.swift. Router pin e221cbd. RED 1, RED 2, GREEN as in the comment above; ProfileFileTests 30/30, the 5 profile and doc suites 57/57.
    - full root `swift test` (after "Build complete!"): exit 1. Failures only in MCP stdio connect tests (ToolModeTests, MCPCompositionTests) and AgentCatalogWatchTests (time limit). The base commit a844424 without this change fails the same tests in a full run (checked with the change set aside, then restored); each suite passes alone. New card ^j5dys15 records them. Thus card test 5 stays open.
    - IntegrationTests: not built. Its build started a llama.cpp submodule clone; I stopped it at once. Its Router pin is still 95c2141.
    - next: a person decides on the llama.cpp clone of the IntegrationTests package; ^j5dys15 for the full-run failures; then /review.
  timestamp: 2026-11-21T12:15:33.064460+00:00
- actor: claude-code
  id: 01m7z0j3nwh5tr2b0wqk4x27k8
  text: |-
    ### implement — stuck
    - correction of the record above: the code work is complete (13 files changed), but two required checks are not complete, so the outcome is stuck, not changed.
    - gap 1: the IntegrationTests package is not built. Its build starts a llama.cpp submodule clone (fresh checkouts in IntegrationTests/.build), and the order says stop on a llama.cpp clone. A person decides if the clone can run (or if IntegrationTests/.build can use the checkouts of the root package).
    - gap 2: the full root `swift test` is not green. The failures (MCP stdio connect tests, AgentCatalogWatchTests) are also on the base commit a844424 without this change; ^j5dys15 records them.
    - next: the decision on the clone; then build IntegrationTests (update its Router pin if needed) and /review.
  timestamp: 2026-11-21T12:16:08.892379+00:00
- actor: claude-code
  id: 01m7zhhcyjhvmpg5v06r25vqmg
  text: |-
    ### review — findings
    - evidence: `review sha d5628d6~1..d5628d6` (HEAD~1..HEAD); 8 files reviewed; 1 finding (1 confirmed, 0 refuted): Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:525. The three bundled profile files were read against the card and Router e221cbdd: no finding. Test item 5 is an orchestrator step, not a finding.
    - next: Correct the item in the "Review Findings (2026-11-21 11:10)" section. Then do the review again. The task stays in review.
  timestamp: 2026-11-21T17:12:51.410840+00:00
position_column: review
position_ordinal: '80'
title: A profile file takes its defaults from the profile config type, not from large.yaml; then large gets kvBits 8
---
User decision, 2026-11-21: "inheriting from large is a bad choice, there should be defaults in the config objects, but assuming large as the default is a mistake". This replaces the rule of ^eq7gjw2 (2026-11-17) that a key that a profile file leaves out comes from the bundled `large`.

## Problem

`ProfileFile.definition(of:name:path:)` merges each profile file over `BundledProfiles.baseKeys` (the keys of `large.yaml`). Thus `large.yaml` is the hidden default of every profile. The user approved `kvBits: 8` for `large` (^wx4ewrs, 2026-11-21), but with this merge each file with no `kvBits` key would also get an 8-bit KV cache. That breaks the documented rule "no `kvBits` key gives fp16" (README, Router `ProfileDefinition`, ProfileFileTests) and the round trip of a saved fp16 profile (`ProfileFile.text(of:)`, Router writes no `kvBits` key for fp16).

## Work

1. Remove the merge over `large.yaml`. Each key that a profile file leaves out takes its default from the profile config type in code (one place, with a doc comment for each default). The default of `kvBits` is no key (fp16). The defaults of the other keys keep the behavior of today where that is sensible (for example the `embedding`, `decision` and context defaults); state each choice on this card.
2. Each bundled profile file (`large`, `medium`, `small`) states each key that differs from the code defaults. `medium` and `small` no longer depend on `large.yaml`.
3. Add `kvBits: 8` to the bundled `large.yaml`.
4. A saved profile loads back as the same profile (round trip), fp16 included.
5. Update README, ARCHITECTURE.md, the doc comments (BundledProfiles, ProfileFile, ProfileStore) and DocumentationSyncTests. Remove the text that says a missing key comes from `large`.

## Tests

- [x] A profile file with no `kvBits` key decodes with an fp16 KV cache, also when `large` has `kvBits: 8`.
- [x] A profile file that names only one key gets the code defaults for each other key, not the keys of `large.yaml`.
- [x] The bundled `large` decodes with an 8-bit KV cache; `medium` and `small` decode as before.
- [x] A saved fp16 profile and a saved 8-bit profile load back the same.
- [ ] `swift test` passes, and the CI integration job is green after the push. #profiles #d203

## Review Findings (2026-11-21 11:10)

> Scope: `review sha d5628d6~1..d5628d6` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 11 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> 5 file(s) not reviewed — no validator matched:
> - `ARCHITECTURE.md` — no validator matches this file
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/profiles/large.yaml` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/profiles/medium.yaml` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/profiles/small.yaml` — no validator matches this file

> The three bundled profile files were also read against this card and Router e221cbdd (`ProfileDefinition`), as the coordinator told. No finding: each file names `description`, `standard` and `kvBits: 8`. The keys that the change removed (`flash`, `embedding`, `decision`, `decisionContext`) are equal to the Router defaults (`flash` = the `standard` list, `defaultEmbeddingCandidates`, `defaultDecisionCandidates` with the same GGUF revision, `defaultDecisionContext` 16384). `large.yaml` has `kvBits: 8` (work item 3). `medium.yaml` and `small.yaml` do not use `large.yaml` (work item 2). `small.yaml` also names its `standard` model, which is equal to the Router default; the implement comment records this choice.
>
> Test item 5 (`swift test` and CI) is an orchestrator step, not a finding of this change.

- [x] `Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift:525` `duplication/duplication` — The description of the `models` tool repeats the default-key facts already written in the description of the `saveProfile` mutation. The phrase "flash: the standard list; kvBits: none, an unquantized KV cache" appears in both places. If Router's defaults or the kvBits meaning change, one copy can be updated and the other left stale, so the two tool descriptions drift apart. Define the shared default text once, for example a `static let` in `ProfileFile` or `BundledProfiles`. Use it in both the `saveProfile` argument description (ModelsGraph.swift:388-389) and `modelsToolDescription` (ToolCatalog.swift:524-525). Each site then keeps only its own surrounding wording.