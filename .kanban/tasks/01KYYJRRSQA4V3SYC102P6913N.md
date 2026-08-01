---
comments:
- actor: claude-code
  id: 01kyyzj9b5525ypmnprrh27ktn
  text: |-
    Research complete. Discoveries:

    - Upstream adoption card ids resolved from sibling boards (grep for `OperationOutcome` in `.kanban/tasks`): Operations `1ad4ydw` (01KYYJQF0S9R8X9N2F61AD4YDW, "Shared terminal-outcome vocabulary: OperationOutcome enum, outcome envelope field, terminal-event contract"), Shelltool `jt19xwc` (01KYYJRRJMZNQCCK87VJT19XWC, "Adopt the shared OperationOutcome vocabulary on detached-command terminal events"), MCP `zfp4a3j` (01KYYJRRRW169DTVE6EZFP4A3J, "Adopt the shared OperationOutcome vocabulary on call terminal events"). All three sit in `done` on their boards — §21 status will read **landed**. A comment on `1ad4ydw` from wballard confirms these exact three downstream cards including this one (2p6913n).
    - plan.md anchor points: §8.4 ToolCallStatus bullet at ~747–752 (currently `_lost` only), §11.5 mapping-decisions list at ~1052–1063 (first bullet is the `_lost` decision; ToolAnnotations bullets follow), §21 table at 1705–1719.
    - `timed_out` decision: map to `failed` with the timeout named in the text — nobody asked for the stop, so `cancelled` would misreport it; will record the rationale in §8.4.
    - Board tasks: `e2xerfm` needs its "Status vocabulary" bullet extended with the one-total-mapping reference (it describes `_lost` handling). `5tfspgc` does NOT mention `_lost` or terminal status at all — its §11.5 scope is composition/transports/elicitation — so no update needed there; leaving it untouched.
  timestamp: 2026-08-01T15:37:29.701844+00:00
- actor: claude-code
  id: 01kyyznf2r1j4dezxgsn3sknw0
  text: |-
    ### implement — changed
    - evidence: plan.md (41+/5-) — §8.4 gains the decision block + total `OperationOutcome → ToolCallStatus` mapping table (timed_out→failed with the timeout named, decision recorded; stopped→cancelled authoritative; cancelled→cancelled advisory with §8.6 honesty note; lost→`_lost` unchanged; unknown→raw under `_` rule §18); §11.5 first mapping decision now derives terminal status from `OperationEvent.outcome` per §8.4, plus a closing note that `ToolAnnotations`-driven decisions (ToolKind, permission gating) are untouched; §21 gains three rows: `1ad4ydw` (OperationTool), `jt19xwc` (Shelltool), `zfp4a3j` (MCP) — all landed. Board: `e2xerfm` description updated with the mapping reference; `5tfspgc` inspected, no `_lost`/status text, left unchanged. Tables verified column-consistent (awk pipe-count).
    - next: /review
    task: ^2p6913n
  timestamp: 2026-08-01T15:39:13.880005+00:00
- actor: claude-code
  id: 01kyyzqq2t4hje9vwf1a73wax8
  text: |-
    ### test — green
    - evidence: `swift build` — Build complete! (1.93 sec), exit 0. `swift test` — "error: no tests found; create a target in the 'Tests' directory" (exit 1), expected/accepted per docs-only change with no test target defined in Package.swift (single `.target(name: "FoundationModelsACPAgent")`, no test target). plan.md table sanity check: §8.4 session/update mapping (lines 729-737, 3-pipe/2-col rows consistent), §8.4 OperationOutcome→ToolCallStatus mapping (lines 759-767, 4-pipe/3-col rows consistent), §21 Upstream dependencies (lines 1738-1755, 5-pipe/4-col rows consistent). No files modified.
    - next: none — docs-only change, build/test gate satisfied
  timestamp: 2026-08-01T15:40:27.610266+00:00
- actor: claude-code
  id: 01kyyzt6ytadq07km7yeqc4w62
  text: |-
    ### commit — changed
    - evidence: 08b46ae plan: tool-call wire status derives from OperationOutcome via one total mapping — 6 files changed, 109 insertions(+), 7 deletions(-): plan.md, .kanban/tasks/01KYSVA1A4HXA6RYSJBE2XERFM.{jsonl,md} (e2xerfm), .kanban/tasks/01KYYJRRSQA4V3SYC102P6913N.{jsonl,md} (2p6913n), .ralph/.gitignore. Not pushed.
    - next: none
    task: ^2p6913n
  timestamp: 2026-08-01T15:41:49.402914+00:00
- actor: claude-code
  id: 01kyyzx78zzt8zg1h4b43eqfq7
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (08b46ae) — engine counts {findings: 0, confirmed: 0, refuted: 0}; directed content check of plan.md §8.4/§11.5/§21 vs card requirements, §8.6 honesty note, §18 `_` rule: zero findings
    - next: none — task done
  timestamp: 2026-08-01T15:43:28.031981+00:00
- actor: claude-code
  id: 01kyyzxsz3cxejf1mf0t54x3qm
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — plan.md §8.4/§11.5/§21 (41+/5-); e2xerfm description synced; 5tfspgc inspected, intentionally unchanged
    - test: green — swift build exit 0; no test target (docs-only, accepted); table pipe-counts consistent
    - commit: 08b46ae
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-01T15:43:47.171616+00:00
position_column: done
position_ordinal: '80'
title: 'plan.md: derive tool-call wire status from the shared OperationOutcome (one total mapping)'
---
## Why

FoundationModelsOperationTool is gaining a shared terminal-outcome vocabulary — `OperationOutcome` (`succeeded` / `failed` / `timed_out` / `stopped` / `cancelled` / `lost`) carried on the `OperationEvent` envelope (card **`1ad4ydw`** on FoundationModelsOperationTool's board), with Shelltool and FoundationModelsMCP migrating to emit it (cards on their boards). This changes the shape of this package's planned §8.4 / §11.5 event-to-wire mapping: instead of parsing per-tool `detail` dialects, the ACP agent can map one envelope enum.

## What

Plan-only update to `plan.md` (this package has no implementation yet — `RoutedACPAgent` is a placeholder):

- **§8.4 (the `session/update` stream)** and **§11.5 (two sinks)**: record that tool-call terminal status on the wire derives from `OperationEvent.outcome` via ONE total function `OperationOutcome → ACP ToolCallStatus`, written once for every event-posting tool rather than per-tool:
  - `succeeded` → `completed`
  - `failed` → `failed`
  - `timed_out` → `failed` (with the timeout named in the text) — or decide otherwise; record the decision
  - `stopped` → `cancelled` (authoritative; the text can say the work was killed)
  - `cancelled` → `cancelled` (advisory; keep the existing honesty note — "we stopped listening")
  - `lost` → `_lost` (existing decision, unchanged: never flatten into `failed`; add "we do not know if this ran" in the text)
  - unknown/`other` → keep the raw value under the `_` extension rule, generic rendering
- Note that MCP's `ToolAnnotations`-driven decisions (`ToolKind`, permission gating) are untouched — this card is only about terminal status.
- Cross-reference the upstream cards in the §21 upstream-dependencies table (Operations `1ad4ydw`, plus the Shelltool and MCP adoption cards) so the implementation task for §8.4 picks the dependency up.