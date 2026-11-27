---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m8ej8n108c43y0kve5380zf4
  text: 'Research: Router f3624eb9 (main) has Router(cluster:clusterOptions:) and Router.clusterReport() (Doctor/RouterClusterReport.swift); LiveModelLoader(cluster:clusterOptions:) must get the same mode (Router doc: "a clustered router gets a loader with the same mode"), so makeLiveModelLoader takes the cluster too. Router does not @_exported FoundationModelsCluster, so this package declares it as a family dependency. ClusterOptions is not Equatable (WorkerSource and Policy are Hashable). Extras has ClusterLoader: Doctorable with healthChecks(of:category:) but internal, so the doctor component maps the ClusterReport itself. ACPAgent compose builds the router before ConfigurationLoader.load() (fallback profile fit), so the user-level cluster section is read first from the defaults+user layers of the configuration stack. Package.resolved is gitignored; `swift package update` moved every sibling to main.'
  timestamp: 2026-11-27T13:14:09.824581+00:00
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