---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Add a keymap key and a fonts section to the configuration
---
From TestudoApp (testudoapp-75). The `settings` endpoint refuses top-level `keymap` with UNKNOWN_SECTION.

- Add `public var keymap` (cua, vim, emacs; default cua), decode in `AgentConfiguration.init(from:)`, a `.scalar` entry in `sectionSchemas`, `keymap: cua` in `Resources/builtin.config.yaml`. The agent does not use it; it keeps it for the host, as `theme`.
- Add a top-level `fonts` section (`FontsConfiguration`: KeyCheckedSection, `family: String?` and `size: Double?` for each role ui/display/code), decode, comment in builtin.config.yaml. For TestudoApp task ^jx3xybc.

Tests for decode, defaults, unknown keys, and the settings endpoint.