---
assignees:
- claude-code
depends_on:
- 01M1MP3H7NCNK2GBQ4HR91KA2S
position_column: todo
position_ordinal: '9080'
title: 'doctor checks: the sandbox, the tools and the MCP servers'
---
### What

cli-plan.md §5.12, the Sandbox and Tools rows. The Skills and Runtime
rows moved to their own card, because six checks across two components
was over the sizing limit.

`ToolsDoctor` in `Sources/FoundationModelsACPAgent/Doctor/`, category
`tools`. It takes the resolved `AgentConfiguration` and an injected
prober, so no test needs a real subprocess or a real network.

- The seatbelt sandbox starts. Run one trivial confined command through
  the injected prober and report the result. A failure is an `.error`.
- Each `sandbox.extraWritePaths` entry exists. A missing path is a
  `.warning` naming it.
- The `tools.shell` store directory is writable. `nil` means the
  capability's own default location, and that is checked too.
- Each configured MCP server: a stdio server's command exists and
  starts; an http server's URL answers. A failure is an `.error` naming
  the server. `tools.mcp` disabled contributes nothing.
- Each disabled tool section reports `.ok` with the word "disabled", so
  a person sees why a tool is absent.

Every prober call carries a timeout. **Name it in seconds in the code**
— the acceptance criterion below asserts against that named value, not
against a vague "its timeout".

- [ ] `ToolsDoctor`, with the injected prober
- [ ] Sandbox, extra paths, shell store, MCP servers
- [ ] A disabled section reports `.ok` and says "disabled"
- [ ] Register it in the doctor component list

### Acceptance Criteria

- [ ] With an injected prober that succeeds everywhere and a default
      roster, every row is `.ok`. **This uses the fixture, not the real
      machine** — the check must be reproducible in CI.
- [ ] A missing `extraWritePaths` entry gives one `.warning` naming it.
- [ ] An MCP server whose command the prober reports absent gives one
      `.error` naming the server and the command.
- [ ] `tools.shell: false` gives one `.ok` row that says disabled, and
      no store-directory check runs.
- [ ] A prober that never answers gives a `.warning` inside the named
      timeout, and the run does not hang.
- [ ] Every `.warning` and `.error` carries a non-nil `fix`.

### Tests

- [ ] `ToolsDoctorTests`: the all-succeed fixture, the missing extra
      path, the unwritable store directory, and a disabled section.
- [ ] The MCP rows against an injected prober: found, missing and
      timeout.
- [ ] A timeout test asserts the elapsed time is under the named bound.
- [ ] A test walks every check and asserts no `.warning` or `.error` has
      a nil `fix`.
- [ ] `swift test` passes.

### Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.