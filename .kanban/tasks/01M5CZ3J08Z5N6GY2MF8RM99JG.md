---
assignees:
- claude-code
depends_on:
- 01M5CZ2K9R4436W0DCWZD0PY0N
position_column: todo
position_ordinal: '8980'
title: 'ACPA-18: MCP server env and header values can be keychain: references'
---
## What
ACPA-18 and D98(d): the tokens of the MCP servers are secrets in the Keychain too. Now `MCPServerConfiguration.Transport` holds `.stdio(env: [String: String])` and `.http(headers: [String: String])` (`ToolSectionCodec.swift:552-627`), and `encode` writes them verbatim (lines 619-625). So `config show`, `config show --json`, `/config` and `/config export` print MCP tokens in clear text.

Do this:
- A value of `env` or `headers` can be `keychain:<name>`. At load, resolve it with the `SecretStore`, the same as `ConfiguredSecret` of card ^zd0py0n. With no item: a `ConfigurationWarning` names the server, the key and the reference; leave that one variable or header out, and keep the server.
- Store each value as a `ConfiguredSecret` (or a small type that holds a reference or a literal), so that encoding writes `keychain:<name>` for a reference.
- A literal `headers` value is redacted in `config show` and `/config` (headers carry tokens). A literal `env` value stays as now, because env also holds values that are not secrets (for example `PATH`); `ToolsDoctor` already warns about secrets in env (`ToolsDoctor.swift:129-133`).
- `MCPComposition` (`MCPComposition.swift:461-467`, line 756) uses the resolved values.
- The client-supplied MCP servers of `session/new` do not change.

## Acceptance Criteria
- [ ] `Authorization: keychain:github-mcp-token` in `headers` sends the value of the item to the server.
- [ ] `GITHUB_TOKEN: keychain:github-token` in `env` gives the value to the child process.
- [ ] `config show` and `/config` show the references, and redact literal header values.
- [ ] A reference with no item gives a warning that names only the reference.

## Tests
- [ ] Load and encode tests with `InMemorySecretStore` for env and headers.
- [ ] A test that the resolved header reaches `httpAdditionalHeaders`.
- [ ] A test that no value is in the `config show` output or a captured log.
- [ ] `swift test` passes with zero failures and zero warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #acpa-18