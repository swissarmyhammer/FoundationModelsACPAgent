# The skills library of the tests

These skills are test artifacts. `SkillsLibraryTests` copies this directory
into the project layer of a session, `<cwd>/.skills/`, and then proves that the
agent mounts them, that the model can load one, and that a hidden skill reaches
no surface.

Each skill is a directory with a `SKILL.md` file, the layout that the skills
package reads. The bodies are short on purpose: a test compares the loaded text
with the file, character for character.

| Skill | What it proves |
|---|---|
| `fixture-explore` | A visible skill. Its body names the `tools.code_context` verbs, as the real code context skills do. |
| `fixture-release-notes` | A second visible skill, so a search must choose between two. |
| `fixture-hidden` | `disable-model-invocation: true`. It must not be in the tool description, in the id enum, or in a search result. |
