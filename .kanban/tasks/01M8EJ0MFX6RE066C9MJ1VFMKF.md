---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8ej8n108c43y0kve5380zf4
  text: 'Research: Router f3624eb9 (main) has Router(cluster:clusterOptions:) and Router.clusterReport() (Doctor/RouterClusterReport.swift); LiveModelLoader(cluster:clusterOptions:) must get the same mode (Router doc: "a clustered router gets a loader with the same mode"), so makeLiveModelLoader takes the cluster too. Router does not @_exported FoundationModelsCluster, so this package declares it as a family dependency. ClusterOptions is not Equatable (WorkerSource and Policy are Hashable). Extras has ClusterLoader: Doctorable with healthChecks(of:category:) but internal, so the doctor component maps the ClusterReport itself. ACPAgent compose builds the router before ConfigurationLoader.load() (fallback profile fit), so the user-level cluster section is read first from the defaults+user layers of the configuration stack. Package.resolved is gitignored; `swift package update` moved every sibling to main.'
  timestamp: 2026-11-27T13:14:09.824581+00:00
- actor: claude-code
  id: 01m8ekhp1aqcw82vgsta1g54vw
  text: |-
    ### implement — changed
    - evidence: commits d3d9fde9 (section), 498684ff (router + live loader + compose), 66f0a99b (login secrets user/password/adminPassword/sshKeyPassphrase, keychain-only, rules, fastSynch test), 09cfa67a (profile `cluster: off`), e20b6c51 (doctor ClusterRouterDoctor). `swift test`: 2934 tests in 316 suites passed (1 known issue, the pre-existing withKnownIssue of HarnessSmokeTests).
    - discoveries: YAML reads a bare `off` as false, so ProfileFile maps `cluster: false` to "off" before Router decodes it. The full load() does not resolve cluster secrets, so the doctor component reports an unresolved reference itself. The session level of `cluster` is ignored (documented in help, builtin file and README), and load() still checks it. A first compose-level test could not fail first (load() also rejects a bad section); replaced with the seam makeRouter(..., userLevelOf:) that compose calls.
    - new cards: ^y4ambta (pre-existing needless-await warnings), ^8mr8xt2 (profile fit source of config show/doctor ignores the cluster).
    - next: /review
  timestamp: 2026-11-27T13:36:34.346758+00:00
- actor: claude-code
  id: 01m8faqtxas7sc35g0apjw8k9a
  text: |-
    ### review — findings
    - evidence: review sha d3d9fde9~1..e20b6c51; 4 findings (4 confirmed, 3 refuted) — Sources/FoundationModelsACPAgent/Configuration/ClusterConfiguration.swift:107, Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift:475, Sources/FoundationModelsACPAgent/Doctor/ClusterRouterDoctor.swift:94, Tests/FoundationModelsACPAgentTests/ClusterRouterCompositionTests.swift:43
    - next: implement the 4 findings in the 2026-11-27 14:16 Review Findings section, then re-review
  timestamp: 2026-11-27T20:21:53.194192+00:00
- actor: claude-code
  id: 01m8far7cf8c9vw32ks9t55b9c
  text: |-
    ### finish iteration 1 — findings
    - implement: (prior commits d3d9fde9..e20b6c51)
    - test: green — 2934 passed (prior)
    - commit: e20b6c51
    - review: findings — ClusterConfiguration.swift:107, ConfigurationLoader.swift:475, ClusterRouterDoctor.swift:94, ClusterRouterCompositionTests.swift:43
  timestamp: 2026-11-27T20:22:05.967335+00:00
- actor: claude-code
  id: 01m8fb8jm030y73g99zftsk8qw
  text: |-
    Implemented the 4 findings of 2026-11-27 14:16.
    - Policy: conforms to CaseInsensitiveChoice (keyName "policy"), custom init(from:) deleted. Discovery: the shared decode matched with `Self(rawValue: word.lowercased())`, which can never match a camelCase raw value (`whenFaster` -> `whenfaster`), so the shared decode now compares each `rawValue.lowercased()` with the lowercased word (same result for the all-lowercase theme/keymap words). The error text now names `policy` rather than `cluster.policy`, as the finding asked; the decode error still carries the coding path.
    - ConfigurationLoader: one private loadDocument(from:) for load() (stack) and loadUserCluster() (userStack).
    - ClusterRouterDoctor: init stores a read of the section (`{ try loader.loadUserCluster() }`) and reads nothing; runHealthChecks() reads it, gives [] for a section that is not enabled, and the sectionError check for one that does not load. isApplicable is gone (the default true): a component with no checks adds nothing to the report, so the doctor output is the same. The Section enum is gone; the test seam takes a throwing section closure. TDD: makingTheComponentReadsNoSecret (counting SecretStore, password login) failed first with reads.count == 1, then passed. Added theChecksReadTheSectionOfTheLoader (unresolved password -> one error, no Router built).
    - Tests: shared `ClusterYAML.cluster(of:)` in Tests/FoundationModelsACPAgentTests/Support/ClusterYAML.swift (internal, so it lives in the test target's Support folder, not the separate TestSupport module); ClusterConfigurationTests.section(of:) deleted, enabledSection() is a one-line call. The now-unused FoundationModelsExtras imports of both suites removed.
  timestamp: 2026-11-27T20:31:01.760522+00:00
- actor: claude-code
  id: 01m8fb8nr32av9gtwwb88ggm8f
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsACPAgent/Configuration/ClusterConfiguration.swift, Sources/FoundationModelsACPAgent/Configuration/AgentConfiguration.swift, Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift, Sources/FoundationModelsACPAgent/Doctor/ClusterRouterDoctor.swift, Tests/FoundationModelsACPAgentTests/Doctor/ClusterRouterDoctorTests.swift, Tests/FoundationModelsACPAgentTests/ClusterConfigurationTests.swift, Tests/FoundationModelsACPAgentTests/ClusterRouterCompositionTests.swift, Tests/FoundationModelsACPAgentTests/Support/ClusterYAML.swift (new). `swift test`: 2935 tests in 316 suites passed (1 known issue, the existing withKnownIssue of HarnessSmokeTests); no warnings in the touched files. Not committed.
    - next: /review
  timestamp: 2026-11-27T20:31:04.963372+00:00
position_column: doing
position_ordinal: '80'
title: 'cluster: section in config.yaml passes a Mac cluster mode and options to the Router'
---
## What
The Router now clusters across Thunderbolt-cabled Macs: `Router(cluster: ClusterMode, clusterOptions: ClusterOptions)` (FoundationModelsRouter d68f5a17, types from FoundationModelsCluster `ClusterMode.swift`, `ClusterLoader.swift` `ClusterOptions`). ACPAgent always builds the Router with the default `.off` (`ComposedAgent.makeRouter`, Sources/FoundationModelsACPAgent/ComposedAgent.swift ~450). Add a `cluster:` section of the user-level `config.yaml` that turns it on.

## Shape (user level only: there is one Router per process)
```yaml
cluster:
  enabled: true            # default false -> ClusterMode.off, today's behavior
  hosts: [m5u2.local]      # optional; absent = Bonjour browse (ClusterOptions.hosts nil)
  sshKey: ~/.ssh/id_ed25519 # optional path; absent = ssh-agent + ~/.ssh (ClusterMode.ssh())
  sshKeyPassphrase: keychain:<name> # optional secret; SSHKey.file(url, passphrase:); needs sshKey
  adminPassword: keychain:<name>    # optional secret; ClusterMode.ssh(key:adminPassword:) (turns off Thunderbolt Bridge on a member)
  user: ml                 # optional; with password gives ClusterMode.password(user:password:)
  password: keychain:<name> # optional secret; the same password on every member
  policy: whenFaster       # whenFaster (default) | whenNeeded | always
  workerDirectory: /path   # optional; folder with fmcluster-worker + mlx.metallib (WorkerSource.directory). Absent = WorkerSource.bundled()
```
No key text in the file (ClusterMode is not Codable on purpose). `~` expands. Added by user approval (via coordinator): `user`, `password`, `adminPassword`, `sshKeyPassphrase`.

## Secrets
- Each secret is a `ConfiguredSecret`, but ONLY its `keychain:<name>` reference form: a literal secret in the cluster section is a load error that says to use keychain:<name>.
- The value resolves through the same SecretStore as ConfigurationLoader (loadUserCluster reads before the router), and goes to FoundationModelsCluster as `ClusterSecret(value)`. Never log or show the value; config show shows the reference.
- Rules: `password` needs `user` and vice versa; `password` with `sshKey` / `adminPassword` / `sshKeyPassphrase` is an error (different modes); `sshKeyPassphrase` needs `sshKey`.
- No fastSynch / opDeadline keys. fastSynch must always be on (user rule): a test checks `options.fastSynch == true` for every enabled shape (key login, password login).

## Notes
- The Router is built before `ConfigurationLoader.load()` in `compose` (the fallback profile uses the router as fit source). Read the cluster section of the user level before `makeRouter`, then pass it in. Session/folder levels of `cluster` are ignored (or rejected) — say which in help.
- Follow the section pattern of `SpotlightConfiguration` (KeyCheckedSection, `sectionKey`, help, CodingKeys, decode defaults), AgentConfiguration CodingKeys/knownKeys, ConfigurationYAML section help.
- `acp-agent doctor` (or `config show`) should show `router.clusterReport()` when cluster is enabled, so a run can be checked before a bench.
- Live path only; `.stub` ignores it.
- Profile files: Router's ProfileDefinition has `cluster: off` (ProfileClusterSetting); ProfileFile.knownKeys must accept `cluster` so a profile with `cluster: off` loads (coordinator review of d3d9fde9).

## Tests (TDD: failing test first)
- Decoding: absent section = off; each key; bad policy fails with a clear error; unknown key rejected.
- `makeRouter` with an enabled section gives a Router whose `cluster.isEnabled` and `clusterOptions` (hosts, policy, workerSource) match.
- compose reads the user-level section before building the router.
- Login secrets: each mode; literal secret error; each rule; unresolved reference error; document shows the reference only; fastSynch on.
- A profile file with `cluster: off` loads and gives `ProfileDefinition.cluster == .off`.
- `doctor` shows the cluster report when enabled.

#cluster

## Review Findings (2026-11-27 14:16)

> Scope: `review sha d3d9fde9~1..e20b6c51` — reviewed the diffs only — lines this change added or modified. 16 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsACPAgent/Resources/builtin.config.yaml` — no validator matches this file

- [x] `Sources/FoundationModelsACPAgent/Configuration/ClusterConfiguration.swift:107` `reuse/reuse` — Policy.init(from:) hand-rolls a case-insensitive word decoder that the existing CaseInsensitiveChoice protocol already provides, duplicating its matching and its 'must be one of' error text, so the choice keys can drift apart when the decode rule changes. Make Policy conform to CaseInsensitiveChoice, supplying `static var keyName` as "policy", and delete its custom init(from:). Keep the test aBadPolicyFailsWithTheChoices passing against the shared error text.
- [x] `Sources/FoundationModelsACPAgent/Configuration/ConfigurationLoader.swift:475` `duplication/duplication` — `loadUserCluster()` repeats the four-line `LayeredYAMLDocument.load(configFileName, from:, engine: TemplateEngine(partials:), context: TemplateContext())` call that `load()` already makes. The only difference is the stack value (`userStack` instead of `stack`). Two copies of the read path that differ only by an argument will drift: a change to how the document is templated or read, such as a new context value, must now be made in both places or the user-level cluster section will be read differently from the other sections. Extract one private helper such as `loadDocument(from layers: DotfolderStack) throws -> LayeredYAMLDocument` that holds the `LayeredYAMLDocument.load` call, and have `loadUserCluster()` call it with `userStack`. Keep `load()` on the same helper, passing `stack`, in the same change so the two reads share one definition.
- [x] `Sources/FoundationModelsACPAgent/Doctor/ClusterRouterDoctor.swift:94` `swift/initialization` — `init(loader:home:huggingFaceTokenProvider:)` reads the configuration files and the Keychain by calling `loader.loadUserCluster()`. The rule says `init` does no slow work, and Keychain access can prompt the user. The file's own doc comment admits this: "The init reads the configuration files and the Keychain.". Store the loader and do the read lazily in `runHealthChecks()`, which is already `async` and can report the failure as the `sectionError` check. Keep `init` to storing `loader`, `home` and the token provider, for example `init(loader:home:huggingFaceTokenProvider:)` storing the values and a `resolveSection()` helper called from `runHealthChecks()`.
- [x] `Tests/FoundationModelsACPAgentTests/ClusterRouterCompositionTests.swift:43` `reuse/reuse` — `enabledSection()` re-implements the parse-and-decode of a `cluster:` section that `ClusterConfigurationTests` already has as `section(of:)`. The two helpers do the same work (`YAMLValue.parse(yaml).decoded(as: AgentConfiguration.self).cluster`), so a fix to the decode path would have to be made in two places. Move the helper to shared test support (for example beside `ConfigurationLoaderTests.Fixture` in `Tests/FoundationModelsACPAgentTestSupport`) as an internal `cluster(of yaml: String)`. Have both suites call it, and keep `enabledSection()` as a one-line call with `enabledYAML` as the argument, or drop it in favour of `cluster(of: enabledYAML)`.
