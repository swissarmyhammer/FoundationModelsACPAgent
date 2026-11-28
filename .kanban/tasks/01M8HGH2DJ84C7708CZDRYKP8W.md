---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffc780
title: A successful session/set_config_option also posts one config_option_update
---
## Problem

The Testudo real-profile check (Qwen3.8-27B, 2026-11-28) found that a pick of "low" in the Reasoning Effort select is applied, but the client never shows it. FoundationModelsACPClient discards the `SetSessionConfigOptionResponse` (`ConnectionSessionRequestSender.swift:75-79`). The agent posts a `config_option_update` only when `reconcileConfigOptions` finds a divergence, and a set records the new state first, so no update goes out. The correct fix is in the client (brief `.briefs/effort/FoundationModelsACPClient-apply-set-config-option-response.md`). This card makes the agent robust for such clients.

## What to do

In `Agent/ConfigOptions.swift`, after a successful set of the model option and of the effort option, post one `config_option_update` with the complete state to the session, in addition to the response.

## Acceptance criteria

- [ ] A set of the effort to `low` gives the response AND one `config_option_update` with `currentValue` `low`.
- [ ] A set of the model gives the response and one `config_option_update`.
- [ ] A failed set posts no update.
- [ ] The next `reconcileConfigOptions` posts nothing more (the state is recorded). #bug