---
assignees:
- claude-code
position_column: done
position_ordinal: '8380'
title: 'ACPA-21 (3): use Router ModelProfiles and Router.estimateFit when ROUTER-12 lands'
---
When Router ROUTER-12 is on main (foundationmodelsrouter-f1):

- Remove the local stand-in `BuiltinProfiles` and the local fit types. Use `ModelProfiles.builtin`, `ModelProfiles.defaultName`, `ModelProfiles.named(_:)` and `ProfileFitEstimate`.
- The agent gives `Router.estimateFit(of:)` as the fit estimate of the models endpoint.
- Run `swift package update`, then all tests. #ACPA-21