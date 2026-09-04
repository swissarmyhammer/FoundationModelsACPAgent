---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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

- [ ] `curl -sI https://huggingface.co/<id>` returns 200 for each of the
      three ids. Record the three results in a task comment.
- [ ] If an id 404s, stop and ask before writing it in. Do not ship a
      default that cannot resolve.
- [ ] Change the three model statics
- [ ] Update the doc comments and the 16 GB figure
- [ ] Update the tests that pin the old ids

## Acceptance Criteria

- [ ] A task comment records a 200 for each of the three ids.
- [ ] `AgentConfiguration()` gives the three new model references.
- [ ] A `config.yaml` that names its own models still wins over each
      default.
- [ ] No default names an MTP repository.
- [ ] `swift build` and `swift test` pass with no warning.

## Tests

- [ ] `ConfigurationLoaderTests`: the empty-stack case asserts the three
      new ids exactly.
- [ ] A new test asserts that no default model reference holds the
      substring `-MTP-`, so a future edit cannot make one a default by
      accident.
- [ ] A new test asserts each default id matches the shape
      `owner/name` — non-empty parts, no whitespace. This is the cheap
      half of the doctor's model check, available immediately.
- [ ] `ProfileResolutionTests` still passes, with its fixtures updated.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.