---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4jyhfnkpbnc92td3dk0h68e
  text: |-
    Research done.
    - 182 files match one of the three patterns of the card (plan.md, bare section mark, "the plan"). Many bare section marks in Sources/acp-agent and the CLI tests point to cli-plan.md, not to plan.md. These stay.
    - cli-plan.md itself cites plan.md about 14 times (for example its table "Where this plan differs from plan.md"). The acceptance rg matches these lines, so cli-plan.md must state those values directly. cli-plan.md stays.
    - README.md links plan.md in its "Documentation" section. DocumentationSyncTests cites plan.md in doc comments only; no test reads plan.md.
    - The README already states the sandbox limit. It does not state the reason for the sandbox-only decision, and it does not state the other cross-cutting decisions (ACP v2 only, no auth, session id = root Router session ULID, transcripts committed and not redacted, unknown session id policy, client MCP servers not persisted).
    Approach: a new README section "Design decisions" holds the cross-cutting decisions. Each local decision goes into the code comment at its location. A new DocumentationSyncTests test makes sure each relative README link resolves, so the README cannot point at a deleted file.
  timestamp: 2026-10-10T13:02:52.595074+00:00
- actor: claude-code
  id: 01m4jyn4nvjjkfrpefj62vg193
  text: 'Implementation started. The files are split among eight parallel sub-agents (Agent session files, Agent prompt files, root/Tools/Commands/Instructions, Configuration/Transcripts/Doctor, Sources/acp-agent + Examples, Package.swift + IntegrationTests + cli-plan.md, unit tests A-L + Doctor, unit tests M-Z + Support + TestSupport). The parent owns README.md, DocumentationSyncTests.swift and the deletion of plan.md. New test: DocumentationSyncTests.readmeRelativeLinksResolve (each relative README link names a file that exists).'
  timestamp: 2026-10-10T13:04:52.411428+00:00
- actor: claude-code
  id: 01m4jzryfy50ww7vet902jkvg8
  text: |-
    Implementation landed (not committed).
    - plan.md is deleted (unstaged deletion). cli-plan.md stays. cli-plan.md no longer names plan.md: its rules are stated in place, and its section 12 is now "Where this plan changed the earlier design", with each old value in words.
    - About 120 source and test files: each plan.md pointer and each bare plan.md section mark is now the decision itself, or is removed where the comment already states it. Remaining bare section marks are cli-plan.md marks (the CLI sections 5.x, 4, 7.1). Remaining "the plan" hits mean an ACP agent plan update or the `config edit` plan value, not plan.md.
    - README.md: new section "Design decisions" (ACP v2 only, no auth, session id = root Router session ULID, one prompt for each session, sandbox-only gate with the reason, transcripts committed, no redaction, client MCP servers not stored, capability on by default, unknown and closed session policy, real delete, compaction changes only the model context, resource_link reads only file:// in the root set). The Documentation section links cli-plan.md in place of plan.md.
    - SandboxConfiguration doc comment now states the full sandbox-only permission decision.
    - Two non-comment changes: the `ConfigurationYAML` header string lost "(plan.md §2.2)" (no test asserts it; the `config show` / `config init` / `/config` header text changes by those words), and the test `inCodeDefaultsMatchThePlan` is now `inCodeDefaultsRecordFullTranscriptsInTheProject`.
    - New test DocumentationSyncTests.readmeRelativeLinksResolve: RED after the deletion of plan.md ("README links to plan.md, which does not exist"), GREEN after the README edit.
    - Note: one sub-agent edited its files with a Python script in the scratchpad instead of the edit tool. The result is comment-only (checked with a diff filter).
    - The build prints "warning: missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS". This is a known swift-build warning about the MLX bundle (recorded on earlier tasks), not a compiler warning from this change.
  timestamp: 2026-10-10T13:24:25.726648+00:00
- actor: claude-code
  id: 01m4jzs24b5svtf087gvdbyh6t
  text: |-
    ### implement — changed
    - evidence: 126 files (plan.md deleted; README.md, cli-plan.md, Package.swift, IntegrationTests/Package.swift, bench/test_swebench_acp.py, and Swift comments under Sources/, Tests/, IntegrationTests/Tests/, Examples/). `rg -n "(^|[^-])plan\.md" --glob '!.kanban/**'` finds nothing. Root suite: `SKILLS_MARKETPLACE_CACHE=<empty> swift test --scratch-path .build/alt --force-resolved-versions` gives 856 tests in 91 suites passed (1 known issue: the deliberate negative of HarnessSmokeTests.orderedSubsequenceAssertionChecksOrderWithGaps). IntegrationTests: `swift test --package-path IntegrationTests --scratch-path IntegrationTests/.build/alt --force-resolved-versions --no-parallel` gives 30 tests in 11 suites passed.
    - next: /review
  timestamp: 2026-10-10T13:24:29.451262+00:00
- actor: claude-code
  id: 01m4k03bm3nzp1qa35aava6kr0
  text: |-
    ### test — green
    - evidence: swift test (scratch .build/alt, empty SKILLS_MARKETPLACE_CACHE) 856 tests in 91 suites passed, 1 known issue (HarnessSmokeTests withKnownIssue); swift test IntegrationTests --no-parallel 30 tests in 11 suites passed; python3 -W error -m unittest discover: bench 254 ran OK (skipped=1, swebench not installed), swebench/scripts 38 OK, swebench-score/scripts 34 OK; rg "(^|[^-])plan\.md" outside .kanban: no match. Only warning: mlx-swift "missing creator for mutated node" (dependency).
    - next: none; no code changed, no commit made.
  timestamp: 2026-10-10T13:30:06.851995+00:00
- actor: claude-code
  id: 01m4k047046xr9gwcrmzfrqfz4
  text: |-
    ### commit — changed
    - evidence: see the commit sha in the log of this branch. Subject: docs: remove plan.md, and write each decision in the README or in a code comment (^av5rym9). 122 files. A first commit 4db116d holds the .kanban/ comment of ^a6mndxz.
    - next: review
  timestamp: 2026-10-10T13:30:34.884889+00:00
- actor: claude-code
  id: 01m4k0xe0yra8zqwf60eg8c7cz
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (14d0828): findings 1, confirmed 1, refuted 1, attempted 84, failed 0. Open: Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift:87 (`completeness/case-sensitivity-coverage`).
    - tool rule `code-hygiene/dead-code-swift` did not finish: SwiftPM could not remove the orphan checkout `.build/checkouts/FoundationModelsMetadataRegistry` (NSCocoaErrorDomain Code=513, Operation not permitted). Its findings are missing.
    - diff check: in the Swift files, the only changed lines that are not comments are the ConfigurationYAML header string, the test rename `inCodeDefaultsMatchThePlan` to `inCodeDefaultsRecordFullTranscriptsInTheProject`, and the new `relativeLinkTargets` / `readmeRelativeLinksResolve` code in DocumentationSyncTests. `rg "(^|[^-])plan\.md"` finds nothing. The cli-plan.md section headings keep their numbers (only the §12 title changed). No hunk only deletes comment text. The hunks that became shorter removed only the `plan.md §x` reference; the decision text stays.
    - next: implement the open finding, then run the review again. Remove the orphan `.build/checkouts/FoundationModelsMetadataRegistry` checkout so that `dead-code-swift` can run.
  timestamp: 2026-10-10T13:44:21.278770+00:00
- actor: claude-code
  id: 01m4k0y25954xx4yrww80hcvy0
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 122 files (plan.md removed)
    - test: green — swift test 856 (1 known issue); IntegrationTests 30; bench 254 (1 skip), swebench 38, swebench-score 34; no plan.md reference
    - commit: 14d0828
    - review: findings — Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift:87; code-hygiene/dead-code-swift did not finish (orphan checkout). The comment-only check passed: only the two named changes and the new link test are not comments.
  timestamp: 2026-10-10T13:44:41.897758+00:00
- actor: claude-code
  id: 01m4k17457sn4ryxwmpzthbjhf
  text: |-
    Finding `completeness/case-sensitivity-coverage` (DocumentationSyncTests.swift) is fixed.
    - RED: new test `relativeLinkTargetsDropsAnUppercaseOrMixedCaseScheme` feeds `HTTPS://example.com`, `Mailto:someone@example.com` and `README.md` through `relativeLinkTargets`. It failed: the result kept the two external links.
    - GREEN: the filter lowercases the link target before the `hasPrefix` check against `externalLinkPrefixes`. The doc comment of `externalLinkPrefixes` says that the prefixes are lowercase and why (RFC 3986).
    - Same cause in the rest of the file: none. The other comparisons are `readme.contains(...)` checks for exact README text, and the `!= "#"` fragment cut, which has no case.
    - `.build/checkouts/FoundationModelsMetadataRegistry` (the orphan checkout) is not touched, by order of the user. Thus `dead-code-swift` can fail again in the next review.
  timestamp: 2026-10-10T13:49:38.855399+00:00
- actor: claude-code
  id: 01m4k176srq4yyxq74bfhv5ery
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift. RED: `swift test --scratch-path .build/alt --force-resolved-versions --filter DocumentationSyncTests/relativeLinkTargetsDropsAnUppercaseOrMixedCaseScheme` failed with 1 issue (got ["HTTPS://example.com", "Mailto:someone@example.com", "README.md"]). GREEN: `--filter DocumentationSyncTests` gives 8 tests in 1 suite passed. The only warning is the known mlx-swift "missing creator for mutated node". The finding is now `- [x]`. Not committed.
    - next: /test, then /review
  timestamp: 2026-10-10T13:49:41.560037+00:00
- actor: claude-code
  id: 01m4k19rv41c010kyxhgaxqeeg
  text: |-
    ### test — green
    - evidence: SKILLS_MARKETPLACE_CACHE=<empty scratch folder> swift test --scratch-path .build/alt --force-resolved-versions — 857 tests in 91 suites passed, 0 failed, 0 skipped, 1 known issue (the intended withKnownIssue in HarnessSmokeTests). Compiler warnings in package files: 0. The only build warning is the mlx-swift dependency (missing creator for mutated node, mlx-swift_Cmlx.bundle). The three "An elicitation answer did not decode" lines are runtime log output of a test that makes that case on purpose.
    - next: review
  timestamp: 2026-10-10T13:51:05.572044+00:00
- actor: claude-code
  id: 01m4k1a7mex3vrhcaebv6z95js
  text: |-
    ### commit — changed
    - evidence: 0a1a548 fix(tests): compare the link scheme without case in the README link test (^av5rym9)
    - next: review
  timestamp: 2026-10-10T13:51:20.718129+00:00
- actor: claude-code
  id: 01m4k1r9t0k0crw9pq1g1bnv4f
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (0a1a548). 1 file reviewed. Counts: 0 findings, 0 confirmed, 0 refuted. 7 validator runs attempted, 0 failed, 0 skipped. The 1 prior finding (DocumentationSyncTests.swift:87) is checked. No tool rule failed because of the `.build` checkout this time.
    - next: none. The task is in done.
  timestamp: 2026-10-10T13:59:01.696143+00:00
- actor: claude-code
  id: 01m4k1rswghs4s4awd0ne9gs2q
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (DocumentationSyncTests.swift)
    - test: green — swift test 857 (1 known issue)
    - commit: 0a1a548
    - review: clean — 0 findings; the prior finding is checked; all 7 validator runs finished (dead-code-swift also ran this time)
  timestamp: 2026-10-10T13:59:18.160099+00:00
position_column: done
position_ordinal: ffb380
title: Remove plan.md and the references to it
---
## Goal

The user says that the plan is old. Delete `plan.md`. Remove or change each reference to it, the direct references and the indirect references, so that each comment stands alone.

## Known references (counted on 2026-10-09)

- Direct: `rg -n "(^|[^-])plan\.md" --glob '!.kanban/**'` gives 581 lines. The files with the most lines are `Agent/SessionSetup.swift` (50), `Agent/PromptExecution.swift` (31), `RoutedACPAgent.swift` (23), `Package.swift` (16), `Agent/SessionLifecycle.swift` (15), `Tools/ToolCatalog.swift` (14), `Commands/CommandRegistry.swift` (14) and `Agent/EventProjection.swift` (14).
- Indirect, section marks: 304 lines in 176 files have a `§` section number and no document name on the same line. Most are the second line of a wrapped `plan.md` reference, or a bare section number of the plan. Examples:
  - `Commands/CommandDispatch.swift:7` (`§14.3`)
  - `Commands/BuiltinCommands.swift:8` (`§14.1`) and `:407` (`§2.2`)
  - `Tools/CatalogContext.swift:38` (`§4.3`)
  - `Doctor/ProfileDoctor.swift:366` (`§7.1`)
  - `RoutedACPAgent.swift:31` (`§5`) and `:172` (`§2.2`)
  - `Package.swift:419` (`§12`)
  Find them with `rg -n '§\s?[0-9]' --glob '!.kanban/**' --glob '!*.md'`.
- Indirect, words: about 590 lines say "the plan", "plan §" or "(plan". Find them with `rg -n -i '\bthe plan\b|plan §|\(plan\b' --glob '!.kanban/**' --glob '!*.md'`. Some of these are not about `plan.md`. Read each one.
- Milestone ids such as `M6`: none found in the Swift sources.
- A `§` that names another document (for example `generation-queue.md §5.5` of FoundationModelsRouter, or the ACP specification) is not a reference to `plan.md`. Keep it.

## Keep `cli-plan.md`

`cli-plan.md` exists, and the user did not say to delete it. Keep it, and keep its references (`RoutedACPAgent.swift`, `Sources/acp-agent/AcpAgentCommand.swift`). It also matches `rg "plan\.md"`, so the acceptance check below excludes it.

## What to change

1. Change each direct and each indirect reference. A comment must give the reason directly. It must not point to a deleted file or to a section number of it.
2. Keep each important recorded decision as short text, in the README or in the code comment at the applicable location. For example, keep the sandbox-only permission decision (`plan.md:1912-1956`).
3. Delete `plan.md`.

## Acceptance

- [x] `plan.md` does not exist. `cli-plan.md` still exists.
- [x] `rg -n "(^|[^-])plan\.md" --glob '!.kanban/**'` finds nothing.
- [x] No comment has a bare `§` section number of the plan, and no comment says "the plan" for `plan.md`.
- [x] The sandbox-only permission decision, and each other decision that the code depends on, is in the README or in a code comment.
- [x] `DocumentationSyncTests` and the full test suite pass.

## Review Findings (2026-10-10 08:30)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 117 file(s) reviewed, 5 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 3 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `cli-plan.md` — no validator matches this file
> - `plan.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/dead-code-swift' failed — the tool judged nothing, so its findings are missing:
> (SwiftPM dependency update log, 228 lines, not copied. The last line is the cause.)
> error: 'foundationmodelsmetadataregistry': Error Domain=NSCocoaErrorDomain Code=513 "“FoundationModelsMetadataRegistry” couldn’t be removed because you don’t have permission to access it." UserInfo={NSUserStringVariant=(
>     Remove
> ), NSFilePath=/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/.build/checkouts/FoundationModelsMetadataRegistry, NSURL=file:///Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/.build/checkouts/FoundationModelsMetadataRegistry, NSUnderlyingError=0x7cff168930 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}}

- [x] `Tests/FoundationModelsACPAgentTests/DocumentationSyncTests.swift:87` `completeness/case-sensitivity-coverage` — The new relative-link filter tests each link target with a case-sensitive hasPrefix against lowercase scheme prefixes (http://, https://, mailto:). URI schemes are case-insensitive (RFC 3986), so a README link written as HTTP://, HTTPS://, or MAILTO: is not recognized as external. It is then treated as a repository path, and readmeRelativeLinksResolve fails on a link that is valid. No test feeds an uppercase or mixed-case scheme through relativeLinkTargets. Compare case-insensitively, for example by lowercasing the target before the hasPrefix check (target.lowercased().hasPrefix($0)). Add one assertion in the suite that passes an uppercase scheme such as HTTPS:// through relativeLinkTargets and expects it to be dropped.