---
depends_on:
- 01KY7ECSJGTV23JVX3D4AXZGQM
position_column: todo
position_ordinal: '8180'
title: 'AgentConfiguration: schema + codec over Extras'' LayeredYAMLDocument'
---
Plan §4. Codable+Sendable+Equatable, constructible in tests with zero file I/O. Sections: profile (standard/flash/embedding candidate lists → Router ProfileDefinition, ModelRef org/repo@rev), tools (built-in sections + mcp list — each mcp entry carries name + either command/args/env for stdio or url for http/s), instructions (replace/append), recording (level → RecordingLevel), transcripts (home|project|absolute), compaction (prompt/budget overrides). Loading: Extras' LayeredYAMLDocument (SHIPPED — Extras rqxez38) over DotfolderStack; unknown top-level keys warn (forward compat for tool sections), unknown nested keys error (typo protection); malformed layer = hard error naming file+line. Defaults directory materialized on first run incl. Instructions.md; <NAME>_DEFAULTS_DIR override. Hermetic fixture tests, userDirectory/environment injection, never the real home.