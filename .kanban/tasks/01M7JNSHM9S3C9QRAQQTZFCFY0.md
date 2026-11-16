---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'D187: transcripts are always in the project; remove transcripts.location and recording.level'
---
Request: testudoapp-75, TestudoApp D187. The words of the user: "i don't want to allow disabling transcripts, or allow changing where they are saved -- i though the ideas is we keep transcripts 'in the project' meaning the cwd so we always keep context".

- Transcripts are always written to `<cwd>/.<name>/transcripts/`.
- Remove the key `transcripts.location` (project, home or an absolute path; AgentConfiguration.swift, used at SessionSetup.swift).
- Remove the key `recording.level` (off or full). Only the doctor reads it; the agent does not give it to Router.
- An old layer that has one of these keys loads. The loader gives a warning, and the agent ignores the key. The settings store refuses a write of such a key.
- Remove the host override `transcriptLocation:` (ConfigurationLoader, ComposedAgent.compose, RoutedACPAgent.init). If a test needs a seam, keep it internal and clearly for tests only.
- Update the doctor (TranscriptsDoctor and the recording check).

Tests (/tdd): a session records under the cwd; an old layer with `transcripts.location: home` or `recording.level: off` loads with a warning and the transcript is in the project; the store refuses a write of each removed key. #D187