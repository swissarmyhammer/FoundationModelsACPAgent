---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
title: 'IntegrationTests: the spawned acp-agent binaries fetch the default skills marketplace from GitHub'
---
## State now

Task ^t87yzmg made the `main` branch of `swissarmyhammer/skills` (HTTPS) the default of `tools.skills.marketplaces`. A session start fetches each marketplace.

- The unit target uses no network: `StubAgentDefaultsLayer`, `AgentConfiguration.withoutMarketplaces` and `ConfigCommandFixture.makeStubEnvironment()` set `marketplaces: []`. A full root run with `SKILLS_MARKETPLACE_CACHE` set to an empty folder left the folder empty.
- `ToolCallingTests` and `SkillTriggerTests` (in-process `LiveAgent`) set `marketplaces: []` in their user layer.
- The suites of `IntegrationTests` that spawn the built binary (CLIProcessTests, ClientInteropTests, ClientServerTests, InterruptTests, OutOfProcessTests, StdioContractTests, TelemetryFlushTests, TelemetryStdoutTests, TranscriptRecordingTests) use the default configuration. A run on 2026-10-10 with `SKILLS_MARKETPLACE_CACHE` set to an empty folder wrote a snapshot of `swissarmyhammer/skills` at `main` into that folder. All 28 tests passed.

## Decide and do

Decide if these end-to-end suites must fetch the real default marketplace, or must be offline and repeatable. If offline: give each spawned child an empty marketplace list in one place (for example a defaults layer through `PipedChildProcess`, or the user layer of `TierThreeFixture`), and keep one test that proves the default path on purpose. Then run IntegrationTests with `--no-parallel` and a probe cache folder, and show that the folder stays empty.

#tests #config