import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The `settings` tool in a session (ACPA-17, D100 (f)): the session gives
/// its `SettingsTool` to the Multitool registry under the noun `settings`,
/// thus the model calls it in `runCode` as `tools.settings.querySettings`,
/// on the same path as a built-in verb.
///
/// The proof reads the file system: the `config.yaml` of the session level
/// of the cwd holds the value that the mutation wrote.
@Suite(.closesHarnesses) struct SettingsToolSessionTests {
    /// The prompt text that starts the scripted `runCode` call.
    private static let promptText = "Change one setting of this folder"

    /// The value of `compaction.trigger` that the mutation writes.
    private static let sessionTrigger = 0.9

    /// The label of the outcome line of the mutation.
    private static let setLabel = "set"

    /// The label of the outcome line of the query.
    private static let readLabel = "read"

    /// The `SettingLevel` and `SettingLayer` name of the session level.
    private static let sessionLevel = SettingsGraphFixture.sessionLevel

    /// The snippet: a `set` mutation on the session level and a `setting`
    /// query, both with no `cwd`. Each call reports the level and the value
    /// of its response on one labeled line, or the whole response when the
    /// response has no setting.
    private static var settingsCode: String {
        """
        const json = (answer) => typeof answer === "string" ? JSON.parse(answer) : answer;
        const set = json(await tools.settings.querySettings({
            query: "mutation { set(keyPath: [\\"compaction\\", \\"trigger\\"], value: \(sessionTrigger), level: \(sessionLevel)) { level } }"
        }));
        const read = json(await tools.settings.querySettings({
            query: "{ setting(keyPath: [\\"compaction\\", \\"trigger\\"]) { value level } }"
        }));
        const setLine = set.data && set.data.set ? set.data.set.level : JSON.stringify(set);
        const readLine = read.data && read.data.setting
            ? read.data.setting.level + " " + read.data.setting.value : JSON.stringify(read);
        return ["\(setLabel)=" + setLine, "\(readLabel)=" + readLine].join("\\n");
        """
    }

    /// A `runCode` call of the session sets a value on the session level
    /// and reads it back with `tools.settings`: the `config.yaml` of the
    /// session level of the cwd holds the value, and the query gives the
    /// value and the session level.
    @Test func aRunCodeCallChangesTheSessionLevelOfTheCwd() async throws {
        let fixture = try await ScriptedPromptFixture.make(
            script: try ScriptedPromptFixture.makeToolPromptScript(code: Self.settingsCode),
            label: "SettingsToolSessionTests-run-code")

        let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: Self.promptText)
        await fixture.close()

        let answer = SkillsLibraryTests.toolCallText(in: run.updates)
        #expect(answer.contains("\(Self.setLabel)=\(Self.sessionLevel)"), "\(answer)")
        #expect(answer.contains("\(Self.readLabel)=\(Self.sessionLevel) \(Self.sessionTrigger)"), "\(answer)")
        let sessionFolder = fixture.cwd.appendingPathComponent(
            ".\(AgentClientHarness.dotfolderName)", isDirectory: true)
        let configText = try textOnDisk(at: ConfigCommandFixture.configURL(in: sessionFolder))
        #expect(configText.contains("trigger: \(Self.sessionTrigger)"), "\(configText)")
    }
}
