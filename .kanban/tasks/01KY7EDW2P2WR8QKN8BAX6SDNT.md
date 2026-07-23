---
position_column: todo
position_ordinal: '8680'
title: Transcript location policy + browse summaries
---
Plan §5. Home-keyed-by-project default (~/.config/<name>/transcripts/<project-slug>/, slug = cwd path with / → -), transcripts.location overrides (project emits .gitignore of * + !.gitignore; absolute wins), lightweight Codable browse summaries (sessions/projects) built from Router's sessions.jsonl + manifest.json via Router's own readers. Never records, never restores — locates and summarizes only; restore is Router's restoreSessionTree.