---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4g9hvsnyshmn455944ds7r0
  text: 'Blocker on step 1 (Multitool pin). `swift package update FoundationModelsMultitool` exits 1. The resolver log (`--very-verbose`) shows "dependency resolution complete!" with only one change: Multitool 24f65ed -> main (c8c74ba). Each other solved pin is equal to the old Package.resolved. Then the command stops with "error: exhausted attempts to resolve the dependencies graph, with the following dependencies unresolved: grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf". These are dependencies of swift-otel 1.5.1 under its OTLPGRPC trait. Package.swift and FoundationModelsACPClient (e1cac1d) both enable only OTLPHTTP, thus Package.resolved has no grpc pin and .build has no grpc checkout. The Multitool Package.swift did not change between 24f65ed and c8c74ba. Package.resolved did not change (it is git-ignored). The last successful update (2026-10-08 12:58) used the same toolchain (Xcode 27.0, Swift 6.4). I asked the user for a hand edit of the Multitool pin; the user said no and asked to discuss the cause in the main session. No source file is changed. Steps 2 to 7 are not started.'
  timestamp: 2026-10-09T12:17:36.053204+00:00
- actor: claude-code
  id: 01m4g9hy4t54988ekrj1c0dcpt
  text: |-
    ### implement — stuck
    - evidence: `swift package update FoundationModelsMultitool` exit 1, "exhausted attempts to resolve the dependencies graph" (unresolved grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf). Package.resolved unchanged (Multitool still 24f65ed). 0 files changed.
    - next: the user discusses the resolve failure in the main session, then decides how to move the pin.
  timestamp: 2026-10-09T12:17:38.458894+00:00
- actor: claude-code
  id: 01m4gbb227f8g4yea2pmmyzra8
  text: |-
    ### Cause of the step 1 blocker (orchestrator, 2026-10-09)

    The resolve failure is a SwiftPM defect that comes and goes. It is not a defect in our manifests.
    - Reproduced in a copy of the package: `swift package update FoundationModelsMultitool` failed one time with the same gRPC error, and the next run of the same command succeeded (exit 0, Multitool c8c74ba, no gRPC pin).
    - The resolver finishes ("dependency resolution complete!"). The error comes in the graph load after the checkout. Each `swift-otel` declaration in the graph enables only `OTLPHTTP`, and every other pin stays the same.
    - A full update takes about 140 s from a cold `.build`. Thus, a 120 s command limit stops it, and it looks hung after "Computed ... swift-syntax at 604.0.0".

    Fix for step 1: run `swift package update FoundationModelsMultitool` with a timeout of at least 600 s. If it fails with this exact gRPC error, run the same command again (up to two more times). Do not hand-edit `Package.resolved`, do not use a local path override, and do not change the `swift-otel` traits.
  timestamp: 2026-10-09T12:48:50.247007+00:00
- actor: claude-code
  id: 01m4gc3q3tt4c4d5e1z23t3edp
  text: 'Step 1 done. `swift package update FoundationModelsMultitool` (timeout 900 s) exit 0 at the first run, duration 777 s. Package.resolved: foundationmodelsmultitool main 24f65ed -> c8c74ba. There is no grpc pin. swift-otel stays 1.5.1. The run printed no other "Updating" pin, and the pin list agrees with the solve of the earlier run (only Multitool moved). Note: Package.resolved is git-ignored, thus git shows no diff for it.'
  timestamp: 2026-10-09T13:02:18.234679+00:00
- actor: claude-code
  id: 01m4gpqb7cw2c0120c1x2t7dk0
  text: 'Progress (implement, 2026-10-09). Step 1 changed by the user: delete both Package.resolved files and run `swift package update` with no name. Old root pins are saved in the scratchpad (root.old.resolved; Multitool 24f65ed, Extras 5c1c638). A second `swift package update FoundationModelsMultitool` moved Multitool to 360d6d0 before the user changed the step. The first full `swift package update` ran 78 min with no output after the "Working copy ... resolved" lines; `sample` showed one thread at full CPU in libSwiftToolsSupport (the machine load average was 65-72 from index builds of other sessions). I stopped it and started the same command again (run 2). Discovery: Multitool c8c74ba/360d6d0 needs a newer FoundationModelsExtras (ToolContext.settling; ToolMount.defaultInlineSettleGrace is gone), thus an update of Multitool alone does not build. Done so far: SwitchOnlyToolOptions<Tool> (generic body with only `enabled`), GitToolOptions and EnvironmentToolOptions are typealiases of it; tools.environment in ToolsConfiguration (CodingKeys, decode, optionKeys); builtin.config.yaml and bench/code-context.config.yaml have `environment: {enabled: true}`; scan.py states tools.environment.enabled (STATED_GROUPS, R["environment_enabled"]); report.py prints "== ENVIRONMENT" and checks environment in COMPARE. New tests in ToolSectionCodecTests, ToolCatalogTests, ToolsDoctorTests, test_scan.py, test_report.py. The Python suites of both skills pass.'
  timestamp: 2026-10-09T16:07:47.180590+00:00
- actor: claude-code
  id: 01m4gpts0k4b8km4c79xaxdvve
  text: 'Progress (implement, step B). Production code is written; it is not built yet, because `swift package update` (run 2, pid 44173) still runs. Changes: ToolCatalog.makeRegistry calls `builder.withEnvironment()` when `tools.environment.mountedOptions != nil` (doc comment names `environment`). ToolsDoctor has the row "the environment tool" after the git row: off gives `DisabledSectionCheck`; on gives `.ok` with a message that names `tools.environment.variables`, the secret risk and `tools.environment.enabled`, and no variable value. README § Tools has the `environment` row and a section with the three verbs, how to set the tool off, and the secret risk. bench/README.md names the `tools.environment` group. BuiltinConfigurationFileTests `eachSwitchableToolIsOnInTheFile` also takes `.environment`. DocumentationSyncTests reads `ToolsConfiguration.CodingKeys.allCases`, thus it needs no change. The repository has no ARCHITECTURE.md.'
  timestamp: 2026-10-09T16:09:39.603775+00:00
- actor: claude-code
  id: 01m4gzbnsfptpm6qnev9vwnqee
  text: 'Cause of the "hang" of `swift package update` (found 2026-10-09 13:30). Run 2 printed its last line at 11:57 ("Working copy of FoundationModelsExtras resolved at main (c18a9aa)"), then ran 90+ min with no output. `sample` showed one thread in a file-tree walk (getattrlist through libSwiftToolsSupport). `lsof` showed the walk deep inside `.build/checkouts/FoundationModelsACPClient/.build/index-build/checkouts/async-http-client/.build/index-build/checkouts/swift-configuration/Examples/.../.build/index-build/...`. Each of the 37 checkouts had its own `.build/index-build` (made 2026-10-08 07:18-07:47), and these trees nest recursively. sourcekit-lsp processes of other sessions make them: `swift-build --experimental-prepare-for-indexing --package-path <repo>/.build/checkouts/<pkg>/.build/index-build/checkouts/...` was running. SwiftPM walks each checkout, so the update takes hours. Action: run 2 stopped; each `.build/checkouts/*/.build` moved to `.build/trash-nested-index/` (the shell tool refuses `rm -rf`; a person can delete that folder); run 3 (pid 44561) started. Risk: the sourcekit-lsp indexers can make the trees again during the run. Pins written by run 2 before the stop: Multitool main 2f8ea80, Router main 16abef2, Extras main c18a9aa (log lines only; Package.resolved was not written by run 2).'
  timestamp: 2026-10-09T18:38:41.970029+00:00
- actor: claude-code
  id: 01m4gzn9xnhdhnpjf9ecy116nb
  text: |-
    Step A done. Root `swift package update`: run 3 exit 1 (the gRPC error "exhausted attempts to resolve the dependencies graph ... grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf"), run 4 exit 1 (same error), run 5 exit 0 (28 s). Each `swift-otel` declaration (root, FoundationModelsACPClient 74fc2df) names only OTLPHTTP, thus the error is the SwiftPM fault that comes and goes. Before each run, each `.build/checkouts/*/.build` that sourcekit-lsp made again was moved to `.build/trash-nested-index/`. `swift package update --package-path IntegrationTests`: run 1 exit 0. No gRPC pin in either file. Root and IntegrationTests now have the same pins.

    Root moved packages (old -> new):
    - foundationmodelsacpclient main e1cac1d -> main 74fc2df
    - foundationmodelsextras main 5c1c638 -> main c18a9aa
    - foundationmodelsmultitool main 24f65ed -> main 2f8ea80 (360d6d0 is an ancestor)
    - foundationmodelsrouter main f9d6870 -> main 16abef2
    - foundationmodelsskills main 2b3695c -> main 53a9201
    - mlx-swift-lm stable 1059f88 -> stable d609e75
    - swift-collections 1.7.1 -> 1.7.2
    - swift-configuration 1.2.1 -> 1.2.2
    - swift-log 1.15.1 -> 1.16.1
    - swift-metrics 2.11.0 -> 2.12.0
    - swift-nio 2.103.0 -> 2.104.0
    - swift-service-lifecycle 2.12.0 -> 2.12.1

    IntegrationTests moved packages (old -> new):
    - foundationmodelsmultitool main ee5509f -> main 2f8ea80
    - foundationmodelsrouter main a149511 -> main 16abef2
    - foundationmodelsskills main 2b3695c -> main 53a9201
    - mlx-swift-lm stable 408f907 -> stable d609e75
  timestamp: 2026-10-09T18:43:57.493965+00:00
- actor: claude-code
  id: 01m4h1ck4df2z8bxzwgbtgbqtr
  text: |-
    ### implement — changed
    - evidence: files touched in this step: Sources/FoundationModelsACPAgent/Tools/ToolCatalog.swift (`withEnvironment()` when `tools.environment.mountedOptions != nil`; doc comment), Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift (row "the environment tool" after git: off -> DisabledSectionCheck, on -> `.ok` with the secret-risk message that names tools.environment.variables and tools.environment.enabled, no value; order and type docs), README.md (§ Tools row and section with the risk), bench/README.md (names the tools.environment group), Tests/.../BuiltinConfigurationFileTests.swift (`.environment` in the switchable list), Tests/.../RunCodeSourceTests.swift and Tests/.../Support/RecordedTranscriptFile.swift (see below). Final Multitool revision: main 2f8ea80 (360d6d0 is an ancestor). Moved packages: see the step A comment (root 12, IntegrationTests 4). `swift build --build-tests`: exit 0, no error; the one warning is the build-system line "missing creator for mutated node: ... mlx-swift_Cmlx.bundle/Contents/MacOS", not from our targets. No source file needed a change for a new package version. One test asserted the old Multitool behavior: RunCodeSourceTests "a failed run reads back its source and its failure" expected that the toolOutput answering a runCode call holds a pending envelope with a completionToken. Multitool 89bc1ca: "a background call that ends inside its settle period returns its own result". The test now reads the answering output as the outcome, and it follows the completionToken to the completion event only when the output names one (a run that continued). Tests: ToolSectionCodecTests, ToolCatalogTests, ToolsDoctorTests, BuiltinConfigurationFileTests, DocumentationSyncTests: 86 tests in 5 suites pass. Full `swift test`: 827 tests in 88 suites pass, 1 known issue (the intended withKnownIssue in HarnessSmokeTests). `swift test --package-path IntegrationTests --no-parallel`: 30 tests in 11 suites pass. Python: bench 254 OK (1 skipped), swebench 38 OK, swebench-score 37 OK. Note: the new Swift tests were not seen RED before the production code, because no build was possible while the package update ran.
    - next: review. A person can delete `.build/trash-nested-index/` (the moved sourcekit-lsp index trees; the shell tool refuses `rm -rf`). The sourcekit-lsp indexers of other sessions make `.build/checkouts/*/.build/index-build` again, and that makes the next `swift package update` slow.
  timestamp: 2026-10-09T19:14:09.165619+00:00
- actor: claude-code
  id: 01m4h1x94fdrskw3pexx1ed7dd
  text: |-
    ### test — green
    - evidence: `swift test` root: 827 tests in 88 suites passed, 1 known issue (the intended withKnownIssue in HarnessSmokeTests orderedSubsequenceAssertionChecksOrderWithGaps). `swift test --package-path IntegrationTests --no-parallel`: 30 tests in 11 suites passed. `python3 -W error -m unittest discover`: bench 254 tests OK (skipped=1), swebench scripts 38 tests OK, swebench-score scripts 37 tests OK. Only build warning in both Swift runs: "missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS" (dependency build-system line). No other warnings. No code was changed.
    - skipped: bench test_swebench_harness.HarnessArgumentsTests.test_the_keys_agree_with_the_real_signature, reason "swebench is not installed".
    - next: none
  timestamp: 2026-10-09T19:23:15.983186+00:00
- actor: claude-code
  id: 01m4h1y4fvmxf7bxjg679p9cmw
  text: |-
    ### commit — changed
    - evidence: 6bc13fa feat(tools): mount the Multitool environment tools, on by default, with tools.environment in the configuration file (^fn8sfpv). Earlier kanban commit: d677ad6.
    - next: none
  timestamp: 2026-10-09T19:23:43.995957+00:00
- actor: claude-code
  id: 01m4h5fd72rgpjs3ms6fbkc18k
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (6bc13fa). 5 findings (5 confirmed, 2 refuted) — .claude/skills/swebench-score/scripts/test_report.py:400, Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift:454, Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift:355 (duplication), Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift:355 (reuse), Tests/FoundationModelsACPAgentTests/Doctor/ToolsDoctorTests.swift:363.
    - next: Do the items of "Review Findings (2026-10-09 14:24)". Then do a new review. The task stays in review.
  timestamp: 2026-10-09T20:25:35.714187+00:00
- actor: claude-code
  id: 01m4h5fyr5hgmevzxb5hybqcdp
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 17 files; all pins made again with a full update (Multitool 2f8ea80)
    - test: green — swift test 827; IntegrationTests 30; bench 254 (1 skip: swebench is not installed), swebench 38, swebench-score 37
    - commit: 6bc13fa
    - review: findings — .claude/skills/swebench-score/scripts/test_report.py:400, Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift:454, Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift:355 (2), Tests/FoundationModelsACPAgentTests/Doctor/ToolsDoctorTests.swift:363
  timestamp: 2026-10-09T20:25:53.669268+00:00
- actor: claude-code
  id: 01m4h60bnk4td5mhb6txdkv552
  text: |-
    Review findings of 2026-10-09 14:24, done (implement pass 2). What changed and why:
    - ToolSectionCodec.swift: `SwitchOnlyToolOptions` has no generic parameter now. The tag protocol `SwitchOnlyTool` and the tags `GitTool` and `EnvironmentTool` are deleted. `GitToolOptions` and `EnvironmentToolOptions` are typealiases of the one struct. No code used the two types as distinct types (no overload, no extension with `where Options ==`), so the phantom tag gave nothing. The `SwitchableToolOptions` doc now names `SwitchOnlyToolOptions`.
    - ToolsDoctor.swift: one private static helper `switchableSectionCheck(name:key:onMessage:)` makes the on/off row. `onMessage: nil` gives the `DisabledSectionCheck` row. `webCheck`, `gitCheck` and `environmentCheck` all call it (webCheck had the same guard/disabled/ok shape, so it is folded too). `shellCheck` and `mcpChecks` have a different shape (a writable-directory check, and an async list of probes), so they stay.
    - ToolsDoctorTests.swift: one parameterized test `aSwitchableSectionThatIsOffSaysDisabled` over `sectionOffCases` (a `SectionOffCase` struct: label, row name, enabled key, and a closure that turns the section off). Cases: web body off, git scalar, git body, environment scalar, environment body. It replaces the web-off, git-off and environment-off tests. A closure is used because `WebToolOptions` is a different type from `SwitchOnlyToolOptions`.
    - test_report.py: a `SwitchOnlyGroup` NamedTuple and `SWITCH_ONLY_GROUPS` (git, environment). Class `TheSwitchOnlyGroupsOfARun` has three subTest loops: the report line states on and the config path, the state function gives off for an off config, and a compare with the group off says "<group> is off before and on now". These replace the git and environment copies of the three tests (the line test and the off-state test had the same cause). `TheGitToolsOfARun` keeps only the two git-history tests. The web compare test stays in `AnUpstreamFixFromTheWebIsInformation`: it uses that class's own report helper with a scan file and asserts other text.
    Note: the rule dump of `dump validators` was 766K characters and the file tool cannot read it whole; the findings and the known rules were applied.
  timestamp: 2026-10-09T20:34:51.187315+00:00
- actor: claude-code
  id: 01m4h60fc3fw451w1fybz51arv
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift, Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift, Tests/FoundationModelsACPAgentTests/Doctor/ToolsDoctorTests.swift, .claude/skills/swebench-score/scripts/test_report.py. `swift test --filter 'ToolSectionCodecTests|ToolsDoctorTests|ToolCatalogTests|BuiltinConfigurationFileTests'`: 78 tests in 4 suites passed (aSwitchableSectionThatIsOffSaysDisabled: 5 cases passed); the only warning is the dependency build line "missing creator for mutated node ... mlx-swift_Cmlx.bundle". `python3 -W error -m unittest discover --start-directory .claude/skills/swebench-score/scripts`: 34 tests OK (was 37: 6 copies removed, 3 parameterized tests added). 5 of 5 findings checked. No Package.resolved change, no git stash, bench/swebench_prompt.py and its test not touched.
    - next: review. The task stays in doing.
  timestamp: 2026-10-09T20:34:54.979983+00:00
- actor: claude-code
  id: 01m4h64t1gx0fj1evmp7hg7y6p
  text: |-
    ### test — green
    - evidence: swift test — 825 tests in 88 suites passed, 1 known issue (the expected withKnownIssue in HarnessSmokeTests), 0 failures. python3 -W error -m unittest discover — bench: 254 tests OK (skipped=1, "swebench is not installed"); .claude/skills/swebench/scripts: 38 OK; .claude/skills/swebench-score/scripts: 34 OK. Only warning: the mlx-swift_Cmlx.bundle build-system line from a dependency.
    - next: none. No files were changed in this iteration.
  timestamp: 2026-10-09T20:37:16.976073+00:00
- actor: claude-code
  id: 01m4h65e9sjgcfcsdrpkvedfnp
  text: |-
    ### commit — changed
    - evidence: cb32765 refactor(tools): make one switch-only options type and one doctor helper for git, environment and web (^fn8sfpv)
    - next: review
  timestamp: 2026-10-09T20:37:37.721332+00:00
- actor: claude-code
  id: 01m4hc04rnw6ypk3skyqd9n029
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (cb32765). 4 files reviewed, 9 validator runs, 0 failed. Counts: 0 findings, 0 confirmed, 0 refuted. The 5 prior findings are all checked.
    - next: none. The task is in done.
  timestamp: 2026-10-09T22:19:35.573491+00:00
- actor: claude-code
  id: 01m4hc0jbfhr3bqp8k3rp0xewb
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 files
    - test: green — swift test 825 (1 known issue, HarnessSmokeTests); bench 254 (1 skip: swebench is not installed), swebench 38, swebench-score 34
    - commit: cb32765
    - review: clean — 0 findings; the 5 prior findings are checked
  timestamp: 2026-10-09T22:19:49.487993+00:00
position_column: done
position_ordinal: ffae80
title: Mount the Multitool environment tools, on by default, with a tools.environment section in the configuration file
---
## Problem

Multitool `origin/main` (c8c74ba) adds the environment capability (commits 1e25640, 3f0e59a, e5b386d). It has three read-only verbs under `tools.environment`:

- `variables` (`name?` or `prefix?`): the environment variables of the process.
- `os`: platform name, version, build, architecture, host name, user name, home directory, processor count, memory and locale.
- `now` (`timeZone?`): the date and the time.

Multitool turns it off by default: "A builder that never calls this renders no `tools.environment` namespace at all" (`MultiToolBuilder+Capabilities.swift`, `withEnvironment()`). This agent does not call `withEnvironment()`. Thus, no session has these tools.

## Decision

The environment tools are ON by default, the same as `git` and `web`. The user asked for this on 2026-10-09.

## Change

1. **Multitool pin.** Move `Package.resolved` to Multitool `origin/main` with `swift package update FoundationModelsMultitool` only. Do not use a local `path:` dependency. Report each package that moves. The push also has the breaking change 89bc1ca: "the settled envelope and `MultiTool.resultInstruction` are gone", and a background call that ends inside its settle period returns its own result. This agent does not name `resultInstruction` now. Make the build and the tests pass, and report each change that the update makes necessary.
2. **Configuration file.** Add `EnvironmentToolOptions` with one key, `enabled` (default `true`). Use the `SwitchableToolOptions` pattern of `GitToolOptions` and `WebToolOptions` in `Configuration/ToolSectionCodec.swift`:
   - Add `environment` to `ToolsConfiguration.CodingKeys` and to `optionKeys`.
   - Accept the short form `environment: false`.
   - `config init`, `config show` and the layer merge must show and merge the section.
3. **Builtin file.** Add `environment: { enabled: true }` with an STE comment to `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml`. The tests of ^9dge8cc require that each key of `optionKeys` is in the file and that the file decodes to `AgentConfiguration()`.
4. **Mount.** In `ToolCatalog.makeRegistry(context:)`, call `builder.withEnvironment()` when `tools.environment.enabled` is true.
5. **Doctor.** Give the environment tools a row in `ToolsDoctor`, with `DisabledSectionCheck` when they are off.
6. **README.** Add an `environment` row to the § Tools table and a short section. The section tells how to set the tools off, and it states the risk below.
7. **Bench config.** Add `environment: { enabled: true }` to `bench/code-context.config.yaml`, so that the run names each tool group (^exkkyyr). Make the scan and the score report state `tools.environment.enabled`, the same as `git`.

## Risk: secrets in the environment

`tools.environment.variables` gives the model each variable of the agent process. This includes secrets, for example the web API keys that `tools.web.apiKeys` reads from the environment. The value then goes into the model context and the transcript. The Multitool API gives the agent no filter (`EnvironmentContext.init` is internal). Do not add a filter in this task. State the risk in the README section, and add a doctor note when `environment` is on. The doctor note must not print a value.

## Tests

- `ToolSectionCodecTests`: decode `environment: false`, `environment: { enabled: false }` and no key (default on). An unknown key is refused. `config init` output reads back to the builtin configuration.
- `BuiltinConfigurationFileTests`: these pass with the new key.
- `ToolCatalogTests`: the default configuration renders `tools.environment.variables`, `os` and `now`. With `enabled: false`, there is no `tools.environment` namespace.
- `ToolsDoctorTests`: the environment row, and the row when it is off.
- One test calls `tools.environment.now` through the registry and gets a `date`.
- The bench and skill Python suites pass with the new config key.

#tools #config

## Review Findings (2026-10-09 14:24)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 6 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 4 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml` — no validator matches this file
> - `bench/README.md` — no validator matches this file
> - `bench/code-context.config.yaml` — no validator matches this file

- [x] `.claude/skills/swebench-score/scripts/test_report.py:400` `reuse/reuse` — test_a_compare_with_environment_off_is_a_compare_of_two_configurations repeats the git compare test at line 374 of this file. It writes the same baseline and asserts the same message shape, with only the group changed. Use one parameterized compare test over the switch-only groups, with the off-config and the expected message as the parameters.
- [x] `Sources/FoundationModelsACPAgent/Configuration/ToolSectionCodec.swift:454` `code-hygiene/dead-code-swift` — generic_type_param `Tool` is unused.
- [x] `Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift:355` `duplication/duplication` — environmentCheck repeats the body of gitCheck. Both guard on mountedOptions() != nil, return DisabledSectionCheck.check(name:key:category:) when the tool is off, and otherwise return .ok(name:message:category:). The two blocks differ only by the property names and the message. A later change to the disabled-row or the on-row shape must be made in both copies, and they can drift apart. Extract one helper, for example `private func switchableSectionCheck(mounted: Bool, name: String, key: String, onMessage: String) -> HealthCheck`, which returns the DisabledSectionCheck row or the .ok row. Have gitCheck and environmentCheck call it with their name, key and message. Keep the gitCheck edit in this change, because its body is in the changed set; if gitCheck is not otherwise touched, it is still the shared shape that the new helper replaces.
- [x] `Sources/FoundationModelsACPAgent/Doctor/ToolsDoctor.swift:355` `reuse/reuse` — environmentCheck repeats the body of gitCheck: a guard on mountedOptions, a DisabledSectionCheck row when the tool is off, and an ok row otherwise. Only the names and the message differ. A fix to one check will be missed in the other. Extract one private helper that takes the section's mountedOptions, the row name, the enabled key, and the on-message. Have gitCheck and environmentCheck call it, so the disabled-row logic exists once.
- [x] `Tests/FoundationModelsACPAgentTests/Doctor/ToolsDoctorTests.swift:363` `reuse/reuse` — The environment-off test repeats the shape of the git-off test at line 320, with the same parameterized sections and the same three checks on the row. Two copies of one behavior drift apart as the tool list grows. Both sections are switch-only tools. Make one parameterized test over the switch-only sections. Each case gives the section, its row name, and its enabled key. Keep the git and environment rows in the parameter list, not in two functions.
