---
assignees:
- claude-code
position_column: done
position_ordinal: fffff480
title: 'ACPA-21 (1): the setting profile.preset selects a builtin profile'
---
Brief: TestudoApp features/packages/foundationmodels-acpagent.md ACPA-21, D189 (TestudoApp ec3296d).

- Add `profile.preset: String` to ProfileConfiguration. The default is `large`.
- Remove `standard`, `flash`, `embedding`, `decision` and `decisionContext` from ProfileConfiguration.
- A layer that has one of the removed keys loads. The loader gives a warning, and the agent ignores the key.
- A name that is not a builtin profile is an error. The error names the profiles. Thus the settings store refuses the write.
- `definition(fallbackName:)` takes the four candidate lists, `description` and `decisionContext` from the preset. `profile.name` is a label only.
- ProfileDoctor checks the models of the preset.
- Until Router ROUTER-12 lands, a local stand-in `BuiltinProfiles` gives the four profiles of the ROUTER-12 table (task 3 replaces it).

Tests (/tdd): the default preset is large; an unknown name is an error that names the profiles; an old layer with `profile.decisionContext` loads with a warning; the definition has the models of the preset. #ACPA-21