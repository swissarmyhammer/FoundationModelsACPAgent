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
  policy: whenFaster       # whenFaster (default) | whenNeeded | always
  workerDirectory: /path   # optional; folder with fmcluster-worker + mlx.metallib (WorkerSource.directory). Absent = WorkerSource.bundled()
```
No passwords or key text in the file (ClusterMode is not Codable on purpose). `~` expands.

## Notes
- The Router is built before `ConfigurationLoader.load()` in `compose` (the fallback profile uses the router as fit source). Read the cluster section of the user level before `makeRouter`, then pass it in. Session/folder levels of `cluster` are ignored (or rejected) — say which in help.
- Follow the section pattern of `SpotlightConfiguration` (KeyCheckedSection, `sectionKey`, help, CodingKeys, decode defaults), AgentConfiguration CodingKeys/knownKeys, ConfigurationYAML section help.
- `acp-agent doctor` (or `config show`) should show `router.clusterReport()` when cluster is enabled, so a run can be checked before a bench.
- Live path only; `.stub` ignores it.

## Tests (TDD: failing test first)
- Decoding: absent section = off; each key; bad policy fails with a clear error; unknown key rejected.
- `makeRouter` with an enabled section gives a Router whose `cluster.isEnabled` and `clusterOptions` (hosts, policy, workerSource) match.
- compose reads the user-level section before building the router.

#cluster