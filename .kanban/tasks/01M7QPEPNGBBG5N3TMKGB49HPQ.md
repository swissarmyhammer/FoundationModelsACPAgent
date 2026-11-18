---
assignees:
- claude-code
depends_on:
- 01M7QPE4FQH8810KJV056R9VP9
position_column: todo
position_ordinal: 8a80
title: 'ACPA-23 (D203): one-time user-level migration of the profile name (small to medium, tiny to small) with a settings-version marker'
---
Decision D203 in `TestudoApp/features/decisions.md` (commit 4ab65e8). Brief: `/Users/wballard/github/swissarmyhammer/.briefs/profiles/acpa-brief.md`, part 4.

## Dependency

^56r9vp9 (the three bundled profiles).

## Why the agent does it

The `acp-agent` CLI (`config`, `profiles`, `run`) reads the same user-level `config.yaml` with no app, and the settings store is the one writer of that file. If the app ran the migration, a CLI user would get the new 9B `small` in place of the 27B model with no notice. TestudoApp writes the name at the user level, key path `["profile"]`. Users of older builds can have `profile: small` (the 27B 4-bit model) or `profile: tiny` (from the four Router profiles of D189).

## Change

When the settings store loads the user level, and the user level has no settings-version marker (for example a top-level key `settingsVersion: 2`, a known key of the loader):

1. `profile: small` becomes `profile: medium`, and `profile: tiny` becomes `profile: small`. Other values stay.
2. The store writes the new value and the marker in one write of the user-level `config.yaml`, with the same write path as `updateSetting`. The comments and the order of the other keys stay.
3. With the marker, the store changes nothing, so a later `small` is the new `small`.
4. Only the user level migrates. A `profile` in a project-level `config.yaml` does not change: `small` there now means the new `small`, and `tiny` gives the warning of the unknown-name task.
5. The marker is a known key, so the loader gives no unknown-key warning for it.
6. The CLI path that loads the user level runs the same migration.
7. README: describe the migration.

## Tests

- A user level with `profile: small` and no marker becomes `profile: medium`, with the marker.
- `tiny` becomes `small`, with the marker.
- A user level with no `profile` key gets only the marker (or no write; choose one and test it).
- A user level with the marker and `profile: small` stays `small`.
- A project level with `profile: small` does not change.
- A second load writes nothing.
- The comments and the key order of the file stay.

When this lands, push to origin/main and send the sha to the TestudoApp session (testudoapp-9a). #d203 #profiles #acpa-23