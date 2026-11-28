---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: The agent config has no `cluster` section, so the cluster mode never gets to the Router
---
## Problem

The config of the user for the cluster3 bench (`~/.config/acp-agent/config.yaml`, 2026-11-27) has a top-level `cluster:` section: `enabled: true`, `hosts: [m5u2.local]`, and `workerDirectory: .../FoundationModelsACPAgent/bench/bin/cluster-ea2da21`. The agent does not know this section. `ConfigurationLoader` gives "unknown section \"cluster\" is ignored", and no code in `Sources/` sends a `ClusterMode` to the Router. Thus the agent never uses the cluster.

The Router takes the cluster mode from the host (`Router.clusterMode(for:)`, `FoundationModelsRouter/Sources/FoundationModelsRouter/Router.swift:141` and `:212`). Each profile can also set `cluster: off` (`ProfileDefinition.cluster`, `ProfileClusterSetting`). The Router cluster integration tests read the same settings from the environment (`ROUTER_CLUSTER_WORKER_DIR`, hosts) in `IntegrationTests/.../ClusterRouterIntegrationTests.swift`.

## What to do

1. Add a top-level `cluster` section to the agent config, with the keys `enabled`, `hosts` and `workerDirectory`. Use the same names and meanings as the Router `ClusterMode` and its options. Read the Router source for the exact type.
2. Give the section to the Router as its cluster mode when the agent starts.
3. Also accept the per-profile `cluster: off` key, if the agent profiles do not accept it yet (`ProfileFile.knownKeys`).
4. `doctor` reports the cluster settings, and it gives no warning for a valid `cluster` section.
5. Ask the user before a change of the format of the existing config file. Do not change the file of the user.

## Acceptance criteria

- [ ] A config with the `cluster` section above loads with no warning.
- [ ] The Router gets a cluster mode with `enabled`, the hosts and the worker folder.
- [ ] A config with no `cluster` section keeps the behavior of today.
- [ ] `doctor` shows the cluster settings.

## Coordination

Do not run cluster tests on the two Macs without a slot from testudoapp-4f. #bug