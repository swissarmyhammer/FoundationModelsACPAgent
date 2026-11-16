---
assignees:
- claude-code
position_column: done
position_ordinal: fffff680
title: 'MCP servers: remove and move the Keychain items that no entry uses'
---
TestudoApp (41b1982) changes MCP servers only through the `mcpServers` mutations. The app does not delete the unused Keychain items now. The agent must do it.

- When a server is removed, or `updateMCPServer` replaces or drops a header or env secret, delete each item `mcp.<server>.header.<n>` / `mcp.<server>.env.<n>` that no entry of `tools.mcp` uses.
- On a rename, move each item to the name of the new server, and change the reference.
- Delete only items of the MCP scheme. Do not touch other `keychain:` references.
- `SecretWriter` gets `removeValue(forReference:)` (Keychain: `SecItemDelete`; no item is not an error).
- Tests use `InMemoryWritableSecretStore`.