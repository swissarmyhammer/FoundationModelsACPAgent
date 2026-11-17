---
assignees:
- claude-code
position_column: done
position_ordinal: fffffa80
title: 'ACPA-22: the statusline settings section'
---
TestudoApp D194/D193: add the `statusline` section so the settings endpoint and tool read and change it. Raw value, two-level key check, builtin `preset: default`, tool help with the presets and the modules. Module keys are a fixed list until AVK-10 gives `StatusLineDefinition.settingsKeys`.