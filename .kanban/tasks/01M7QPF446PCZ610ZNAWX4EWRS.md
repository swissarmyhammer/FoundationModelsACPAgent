---
assignees:
- claude-code
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: todo
position_ordinal: 8c80
title: 'ACPA-23 (D203): real Mac check of small (MTP, kvBits 8), and measure kvBits 8 for large and medium — downloads approved'
---
Decision D203 in `TestudoApp/features/decisions.md` (commit 4ab65e8). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/profiles/acpa-brief.md`, part 1 (the measurement) and the last test. Facts: `research.md` in the same folder.

## Dependency

^56r9vp9 (the three bundled profiles).

## Downloads

- The user removed the download gate (2026-11-20). The task downloads the models of each profile through the product's own path (Router's profile resolution at the first `session/new`), with no question to the user: `small` is about 9.4 GB, `medium` about 19.3 GB, `large` about 33.9 GB (with the embedding and decision models).
- Do not change `kvBits` of `large` or `medium` without a go from the user. Propose the change only.

## Work

1. On a real Mac: a session with the `small` profile loads and answers with the MTP drafter and `kvBits: 8`. `research.md` says that this path is not verified. Report the result (load time, memory, window, tokens per second, drafter acceptance if available) to the user.
2. Measure `kvBits: 8` for `large` and `medium`: quality on the same prompts, the window that the fit estimate gives, and the speed. If `kvBits: 8` gives the same quality and a larger window, propose the change to the user. Change the profile files only with a go.
3. Record the results on this task.

## Tests

- No unit test. The result is a record on this task and a report to the user. #d203 #profiles #acpa-23 