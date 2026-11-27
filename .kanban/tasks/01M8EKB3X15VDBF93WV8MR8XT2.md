---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8fc3t8yx1xpnypebadhhjd3
  text: 'Research: makeProfileFitSource (ComposedAgent) calls makeRouter(for:home:hf:) with the default ClusterConfiguration(), so the cluster is off. compose uses makeRouter(..., userLevelOf: loader), which calls loader.loadUserCluster() — that resolves keychain: references through the secret store, so an eager reuse would read the Keychain at build time. Only caller of makeProfileFitSource: AgentComposition.fallbackProfileName (config show, doctor, config init tests use a stub fitSource). Decision (from the dispatcher): the fit source reads the user-level section through the same makeRouter(userLevelOf:) path, built lazily on the first fit (a deferred fit source, cached), so building reads no Keychain item, like ClusterRouterDoctor. A section that does not load gives a no-fit report (fallback then is small) and a configuration warning log; doctor''s ClusterRouterDoctor reports the section error itself. fallbackProfileName gets workingDirectory + secretStore so it builds the same CLI loader as config show/doctor.'
  timestamp: 2026-11-27T20:45:54.334396+00:00
- actor: claude-code
  id: 01m8fcckqs6d03rksewz7y8v94
  text: |-
    ### implement — changed
    - Decision: the fit source reads the user-level cluster section. ComposedAgent.makeProfileFitSource(for:home:huggingFaceTokenProvider:userLevelOf:) now returns a DeferredRouterFitSource (new actor, Models/DeferredRouterFitSource.swift). On the first fit it builds the router through the same makeRouter(..., userLevelOf:) path that compose uses, then keeps it. Building the source reads no Keychain item. A section that does not load gives a no-fit report with the error as its failure, plus a configuration warning log, so the fallback is small. The doc now matches the behaviour. The function no longer throws.
    - AgentComposition.fallbackProfileName gained workingDirectory: and secretStore:. It builds the CLI loader (makeConfigurationLoader) and gets the home from it. config show passes its secretStore through. doctor passes --cwd.
    - TDD: 3 new tests in ClusterRouterCompositionTests ("The fit source"). RED was a compile failure (missing userLevelOf: / DeferredRouterFitSource). GREEN: 13/13 in the suite. CountingSecretStore moved from ClusterRouterDoctorTests into Support/ so both suites share it. ARCHITECTURE.md D203 paragraph updated.
    - evidence: swift test, 2938 tests in 316 suites passed, 0 failures, 0 warnings (1 known issue is the pre-existing withKnownIssue in HarnessSmokeTests).
    - next: /review
  timestamp: 2026-11-27T20:50:42.553725+00:00
- actor: claude-code
  id: 01m8fcfdfh7yhc91zc9ne304qd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (13b6fc8b) — 0 findings, 0 confirmed, 2 refuted; 7 validator runs attempted, 0 failed; 9 files reviewed; not reviewed: 2 .kanban files (.reviewignore), ARCHITECTURE.md (no validator)
    - next: none — task moved to done
  timestamp: 2026-11-27T20:52:14.449315+00:00
- actor: claude-code
  id: 01m8fcfpevqjkk4g5ms7zw8vyq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 files
    - test: green — swift test 2938 passed
    - commit: 13b6fc8b
    - review: clean
  timestamp: 2026-11-27T20:52:23.643915+00:00
position_column: done
position_ordinal: ffffffc580
title: profile fit source of config show and doctor ignores the cluster section
---
`ComposedAgent.makeProfileFitSource` (used by `config show`, `doctor`, `AgentComposition.fallbackProfileName`) builds its Router with the cluster off, while `compose` now builds its Router with the user-level `cluster:` section (^j1vfmkf). With a cluster enabled, the Router sizes the `standard` slot with the cluster planner, so the fallback profile (the largest bundled profile that fits) can differ between the agent and those commands; the doc of makeProfileFitSource says "It gives the same fit as the router of compose". Decide whether the fit source should read the section too (it would then run cluster discovery for a fit), and make the doc true either way.