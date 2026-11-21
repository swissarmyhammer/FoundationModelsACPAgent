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
position_column: doing
position_ordinal: '8280'
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

- [ ] A profile file with no `kvBits` key decodes with an fp16 KV cache, also when `large` has `kvBits: 8`.
- [ ] A profile file that names only one key gets the code defaults for each other key, not the keys of `large.yaml`.
- [ ] The bundled `large` decodes with an 8-bit KV cache; `medium` and `small` decode as before.
- [ ] A saved fp16 profile and a saved 8-bit profile load back the same.
- [ ] `swift test` passes, and the CI integration job is green after the push. #profiles #d203