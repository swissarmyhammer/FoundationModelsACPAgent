---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: profile fit source of config show and doctor ignores the cluster section
---
`ComposedAgent.makeProfileFitSource` (used by `config show`, `doctor`, `AgentComposition.fallbackProfileName`) builds its Router with the cluster off, while `compose` now builds its Router with the user-level `cluster:` section (^j1vfmkf). With a cluster enabled, the Router sizes the `standard` slot with the cluster planner, so the fallback profile (the largest bundled profile that fits) can differ between the agent and those commands; the doc of makeProfileFitSource says "It gives the same fit as the router of compose". Decide whether the fit source should read the section too (it would then run cluster discovery for a fit), and make the doc true either way.