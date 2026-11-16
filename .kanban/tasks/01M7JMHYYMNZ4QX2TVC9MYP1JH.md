---
assignees:
- claude-code
position_column: done
position_ordinal: fffff580
title: 'ACPA-21 (2): Query.profiles on the models endpoint'
---
Brief: TestudoApp ACPA-21.

- Add `Query.profiles: [ModelProfile!]!`, with one row for each builtin profile, in the order of the list. Fields: name, description, selected, active, restartRequired, models (one ProfileModel row for each slot, with the ModelChoice fields), downloadBytes (each model and drafter counted one time; null when a size is not known), presentBytes, state, fit (ProfileFit: FITS, DOES_NOT_FIT, UNKNOWN), requiredBytes, budgetBytes, fitError.
- `Query.models` gives the slot models of the selected profile. It is read-only.
- Remove `Query.choices(slot:)`.
- Add the change reason PROFILE (appliesAt NEXT_LAUNCH) for a change of `profile.preset` at the user level.
- `ModelsGraph.init` gets a fit-estimate parameter. Thus a host can make the endpoint before the agent exists.

Tests (/tdd), with a stub storage and a stub fit estimate: one row for each builtin profile; a model of two slots counts one time in downloadBytes; selected follows profile.preset; a write of profile.preset gives a PROFILE change. #ACPA-21