import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The `settings` GraphQL endpoint (ACPA-17, D100, D75): the merged value of
/// a key and its level, the `set` and `clear` mutations on
/// each level, and the rules of a secret key.
///
/// Each test uses ``SettingsGraphFixture``: temporary folders and an
/// ``InMemorySecretStore``. The tests of the read after a change use a
/// ``FailingSecretStore``.
@Suite struct SettingsGraphTests {
    // MARK: - Constants

    /// The value of `compaction.trigger` that the user level sets.
    private static let userTrigger = 0.7

    /// The value of `compaction.trigger` that a session level sets.
    private static let sessionTrigger = 0.9

    /// The reference name of the Tavily key.
    private static let referenceName = "tavily-api-key"

    /// The reference of the Tavily key, as the file holds it.
    private static let reference = "keychain:\(referenceName)"

    /// A second reference of the Tavily key, which a session level holds.
    private static let sessionReference = "keychain:session-tavily-api-key"

    /// A session `config.yaml` that is not valid YAML, thus the store cannot
    /// read the level.
    private static let brokenYAML = "compaction: [unclosed\n"

    /// The value that the secret store holds for ``referenceName``.
    private static let secretValue = "settings-graph-secret-7c41aa"

    /// A literal key that a call gives for a secret key.
    private static let literalKey = "tvly-literal-0a9d2e"

    /// A user `config.yaml` whose Tavily key is a literal.
    private static let literalYAML = "tools:\n  web:\n    apiKeys:\n      tavily: \(literalKey)\n"

    /// The environment variable that the template test renders. Each process
    /// environment has it.
    private static let templateVariable = "HOME"

    /// A user `config.yaml` that sets `compaction.trigger` inside a block tag.
    private static let blockYAML =
        "{% if \(templateVariable) %}\ncompaction:\n  trigger: \(userTrigger)\n{% endif %}\n"

    /// The name of the golden file of the schema, under `Tests/Fixtures`.
    private static let goldenFileName = "settings.graphql"

    /// A key that no section of the configuration has.
    private static let unknownSection = "nosuchsection"

    /// A working directory that is not an absolute path.
    private static let relativeDirectory = "relative/folder"

    // MARK: - The endpoint contract

    /// The endpoint has the name `settings`, the server scope, an SDL schema
    /// that builds, and the response conventions of the toolkit, and it
    /// rewrites an alias name.
    @Test func theEndpointConforms() async throws {
        let fixture = try SettingsGraphFixture(label: "conformance")
        let probe = GraphQLAliasProbe(
            query: "query($cwd: String!) { setting(key: [\"compaction\", \"trigger\"], cwd: $cwd) { level } }",
            variables: ["cwd": .string(fixture.firstDirectory.path)],
            from: "key", to: "keyPath")

        let problems = await GraphQLEndpointConformance.problems(of: fixture.graph, scope: .server, probe: probe)

        #expect(problems.isEmpty)
        #expect(fixture.graph.name == SettingsGraph.endpointName)
    }

    /// Each type, field, argument and enum value of the schema has a
    /// description, because the agent learns the schema with introspection.
    @Test func eachPartOfTheSchemaHasADescription() throws {
        let fixture = try SettingsGraphFixture(label: "descriptions")

        let undescribed = try GraphQLSchemaDescriptions.undescribed(in: buildSchema(source: fixture.graph.schema))

        #expect(undescribed.isEmpty)
    }

    /// The SDL schema is the schema in the golden file.
    @Test func theSchemaMatchesTheGoldenFile() throws {
        let fixture = try SettingsGraphFixture(label: "golden")
        let goldenFile = try PackageRoot.directory()
            .appendingPathComponent("Tests/Fixtures")
            .appendingPathComponent(Self.goldenFileName)

        #expect(GraphQLSchemaGolden.problems(of: fixture.graph.schema, against: goldenFile).isEmpty)
    }

    // MARK: - Query

    /// A query gives the merged value of a key for a session and the level
    /// that set it: the session level, the user level, or the builtin layer.
    @Test func aQueryGivesTheMergedValueAndItsLevel() async throws {
        let fixture = try SettingsGraphFixture(label: "query")
        try await fixture.store.set(
            .double(Self.userTrigger), at: SettingsGraphFixture.triggerKeyPath, level: .user)
        try await fixture.store.set(
            .double(Self.sessionTrigger), at: SettingsGraphFixture.triggerKeyPath,
            level: .session(fixture.firstDirectory))

        let session = try await fixture.setting(SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
            .object("setting")
        let user = try await fixture.setting(SettingsGraphFixture.triggerKeyPath, cwd: fixture.secondDirectory)
            .object("setting")
        let builtin = try await fixture.setting(["tools", "mcp"], cwd: fixture.firstDirectory)
            .object("setting")

        #expect(session["value"] as? Double == Self.sessionTrigger)
        #expect(session["level"] as? String == SettingsGraphFixture.sessionLevel)
        #expect(session["keyPath"] as? [String] == SettingsGraphFixture.triggerKeyPath)
        #expect(user["value"] as? Double == Self.userTrigger)
        #expect(user["level"] as? String == SettingsGraphFixture.userLevel)
        #expect(builtin["level"] as? String == SettingsGraphFixture.builtinLayer)
    }

    /// A key that no layer and no builtin default has gives `null`.
    @Test func aKeyWithNoValueGivesNull() async throws {
        let fixture = try SettingsGraphFixture(label: "null")

        let reply = try await fixture.setting(["compaction", "hardCeiling"], cwd: fixture.firstDirectory)

        #expect(reply.codes.isEmpty)
        #expect(reply.data?["setting"] is NSNull)
    }

    /// The `sections` query gives the top-level keys of the configuration.
    @Test func theSectionsAreTheKeysOfTheConfiguration() async throws {
        let fixture = try SettingsGraphFixture(label: "sections")

        let reply = try await fixture.run("{ sections }")

        #expect(reply.data?["sections"] as? [String] == AgentConfiguration.CodingKeys.allCases.map(\.stringValue))
    }

    // MARK: - Mutations

    /// A `set` on the user level changes the value of each session
    /// that does not set the key.
    @Test func aSetOnTheUserLevelWorks() async throws {
        let fixture = try SettingsGraphFixture(label: "set-user")

        let reply = try await fixture.set(
            .number(Number(Self.userTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)

        #expect(reply.codes.isEmpty)
        let result = try reply.object("set")
        #expect(result["value"] as? Double == Self.userTrigger)
        #expect(result["level"] as? String == SettingsGraphFixture.userLevel)
        let other = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.secondDirectory)
        #expect(other == SettingsValue(value: .double(Self.userTrigger), level: .user))
    }

    /// A `set` on the session level wins for that session only.
    @Test func aSetOnTheSessionLevelWorks() async throws {
        let fixture = try SettingsGraphFixture(label: "set-session")
        try await fixture.store.set(
            .double(Self.userTrigger), at: SettingsGraphFixture.triggerKeyPath, level: .user)

        let reply = try await fixture.set(
            .number(Number(Self.sessionTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)

        let result = try reply.object("set")
        #expect(result["value"] as? Double == Self.sessionTrigger)
        #expect(result["level"] as? String == SettingsGraphFixture.sessionLevel)
        let other = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.secondDirectory)
        #expect(other == SettingsValue(value: .double(Self.userTrigger), level: .user))
    }

    /// A `clear` on the session level makes the user value apply again.
    @Test func aClearOnTheSessionLevelRestoresTheUserValue() async throws {
        let fixture = try SettingsGraphFixture(label: "clear-session")
        try await fixture.store.set(
            .double(Self.userTrigger), at: SettingsGraphFixture.triggerKeyPath, level: .user)
        try await fixture.store.set(
            .double(Self.sessionTrigger), at: SettingsGraphFixture.triggerKeyPath,
            level: .session(fixture.firstDirectory))

        let reply = try await fixture.clear(
            SettingsGraphFixture.triggerKeyPath, level: SettingsGraphFixture.sessionLevel,
            cwd: fixture.firstDirectory)

        let result = try reply.object("clear")
        #expect(result["value"] as? Double == Self.userTrigger)
        #expect(result["level"] as? String == SettingsGraphFixture.userLevel)
    }

    /// A mutation name that a call writes in place of `set` or `clear`, such
    /// as `setSetting` or `unset`, reaches the mutation of the schema.
    @Test func aMutationAliasReachesTheMutation() async throws {
        let fixture = try SettingsGraphFixture(label: "mutation-alias")
        var variables = SettingsGraphFixture.variables(
            keyPath: SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
        variables["level"] = .string(SettingsGraphFixture.userLevel)
        variables["value"] = .number(Number(Self.userTrigger))

        let set = try await fixture.run(
            "mutation($keyPath: [String!]!, $value: JSON!, $level: SettingLevel!, $cwd: String!) "
                + "{ setSetting(keyPath: $keyPath, value: $value, level: $level, cwd: $cwd) { level } }",
            variables: variables)
        variables["value"] = nil
        let clear = try await fixture.run(
            "mutation($keyPath: [String!]!, $level: SettingLevel!, $cwd: String!) "
                + "{ unset(keyPath: $keyPath, level: $level, cwd: $cwd) { level } }",
            variables: variables)

        #expect(set.codes.isEmpty)
        #expect(try set.object("setSetting")["level"] as? String == SettingsGraphFixture.userLevel)
        #expect(clear.codes.isEmpty)
        let stored = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
        #expect(stored == nil)
    }

    /// A change that would lose a template construct of the file is refused
    /// with a clear error, and the file does not change.
    @Test func aChangeThatWouldLoseATemplateIsRefused() async throws {
        let fixture = try SettingsGraphFixture(label: "template")
        let userRoot = try fixture.userRoot
        try ConfigFileFixture.write(Self.blockYAML, in: userRoot)

        let reply = try await fixture.set(
            .number(Number(Self.sessionTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)

        #expect(reply.codes == [SettingsGraphError.templateNotKept(keyPath: "").code])
        #expect(reply.messages.first?.contains(SettingsGraphFixture.triggerKeyPath.joined(separator: ".")) == true)
        #expect(try textOnDisk(at: ConfigCommandFixture.configURL(in: userRoot)) == Self.blockYAML)
    }

    /// A key path whose first key is not a section of the configuration is
    /// refused, and the error names the sections.
    @Test func aKeyOutsideTheSectionsIsRefused() async throws {
        let fixture = try SettingsGraphFixture(label: "unknown-section")

        let reply = try await fixture.set(
            .bool(true), at: [Self.unknownSection, "key"], level: SettingsGraphFixture.userLevel,
            cwd: fixture.firstDirectory)

        #expect(reply.codes == [SettingsGraphError.unknownSection(key: "").code])
        #expect(reply.messages.first?.contains(AgentConfiguration.CodingKeys.compaction.stringValue) == true)
    }

    /// A working directory that is not an absolute path is refused.
    @Test func aRelativeWorkingDirectoryIsRefused() async throws {
        let fixture = try SettingsGraphFixture(label: "relative")

        let reply = try await fixture.run(
            SettingsGraphFixture.settingQuery,
            variables: [
                "keyPath": .array(SettingsGraphFixture.triggerKeyPath.map(Map.string)),
                "cwd": .string(Self.relativeDirectory),
            ])

        #expect(reply.codes == [SettingsGraphError.relativeWorkingDirectory(path: "").code])
    }

    // MARK: - No working directory

    /// The endpoint has no session folder, thus it refuses a `set` and a
    /// `clear` on the session level that give no working directory, and the
    /// user level does not change.
    @Test func aSessionChangeWithNoWorkingDirectoryIsRefused() async throws {
        let fixture = try SettingsGraphFixture(label: "no-cwd-session")

        let set = try await fixture.set(
            .number(Number(Self.sessionTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.sessionLevel, cwd: nil)
        let clear = try await fixture.clear(
            SettingsGraphFixture.triggerKeyPath, level: SettingsGraphFixture.sessionLevel, cwd: nil)

        #expect(set.codes == [SettingsGraphError.missingWorkingDirectory.code])
        #expect(clear.codes == [SettingsGraphError.missingWorkingDirectory.code])
        #expect(try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: nil) == nil)
    }

    /// A `set` on the user level with no working directory writes
    /// `<root>/config.yaml`, and its result is the user value.
    @Test func aUserSetWithNoWorkingDirectoryWritesTheUserFile() async throws {
        let fixture = try SettingsGraphFixture(label: "no-cwd-user-set")

        let reply = try await fixture.set(
            .number(Number(Self.userTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: nil)

        #expect(reply.codes.isEmpty)
        let result = try reply.object("set")
        #expect(result["value"] as? Double == Self.userTrigger)
        #expect(result["level"] as? String == SettingsGraphFixture.userLevel)
        let text = try textOnDisk(at: ConfigCommandFixture.configURL(in: fixture.userRoot))
        #expect(try YAMLValue.parse(text).value(at: SettingsGraphFixture.triggerKeyPath) == .double(Self.userTrigger))
    }

    /// A `clear` on the user level with no working directory removes the key
    /// from `<root>/config.yaml`. No lower layer has the key, thus the result
    /// is `null`.
    @Test func aUserClearWithNoWorkingDirectoryRemovesTheUserValue() async throws {
        let fixture = try SettingsGraphFixture(label: "no-cwd-user-clear")
        try await fixture.store.set(
            .double(Self.userTrigger), at: SettingsGraphFixture.triggerKeyPath, level: .user)

        let reply = try await fixture.clear(
            SettingsGraphFixture.triggerKeyPath, level: SettingsGraphFixture.userLevel, cwd: nil)

        #expect(reply.codes.isEmpty)
        #expect(reply.data?["clear"] is NSNull)
        let text = try textOnDisk(at: ConfigCommandFixture.configURL(in: fixture.userRoot))
        #expect(try YAMLValue.parse(text).value(at: SettingsGraphFixture.triggerKeyPath) == nil)
    }

    /// A query with no working directory gives the user level over the
    /// builtin layer. The session level of a folder does not apply.
    @Test func aQueryWithNoWorkingDirectoryReadsTheUserLevel() async throws {
        let fixture = try SettingsGraphFixture(label: "no-cwd-query")
        try await fixture.store.set(
            .double(Self.userTrigger), at: SettingsGraphFixture.triggerKeyPath, level: .user)
        try await fixture.store.set(
            .double(Self.sessionTrigger), at: SettingsGraphFixture.triggerKeyPath,
            level: .session(fixture.firstDirectory))

        let user = try await fixture.setting(SettingsGraphFixture.triggerKeyPath, cwd: nil).object("setting")
        let builtin = try await fixture.setting(["tools", "mcp"], cwd: nil).object("setting")

        #expect(user["value"] as? Double == Self.userTrigger)
        #expect(user["level"] as? String == SettingsGraphFixture.userLevel)
        #expect(builtin["level"] as? String == SettingsGraphFixture.builtinLayer)
    }

    // MARK: - Secrets

    /// A literal value for a secret key is refused with a message that asks
    /// for a `keychain:` reference, and the response does not hold the value.
    @Test func aLiteralValueForASecretKeyIsRefused() async throws {
        let fixture = try SettingsGraphFixture(label: "secret-literal")

        let reply = try await fixture.set(
            .string(Self.literalKey), at: SettingsGraphFixture.tavilyKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)

        #expect(reply.codes == [SettingsGraphError.secretNeedsReference(keyPath: "").code])
        #expect(reply.messages.first?.contains(ConfiguredSecret.referencePrefix) == true)
        #expect(!reply.text.contains(Self.literalKey))
        let stored = try await fixture.store.value(at: SettingsGraphFixture.tavilyKeyPath, cwd: fixture.firstDirectory)
        #expect(stored == nil)
    }

    /// A literal secret inside the value of a whole section is refused too.
    @Test func aLiteralSecretInsideASectionIsRefused() async throws {
        let fixture = try SettingsGraphFixture(label: "secret-section")
        let web: Map = ["apiKeys": ["tavily": .string(Self.literalKey)]]

        let reply = try await fixture.set(
            web, at: SettingsGraphFixture.webKeyPath, level: SettingsGraphFixture.sessionLevel,
            cwd: fixture.firstDirectory)

        #expect(reply.codes == [SettingsGraphError.secretNeedsReference(keyPath: "").code])
        #expect(reply.messages.first?.contains(SettingsGraphFixture.tavilyDottedKeyPath) == true)
        #expect(!reply.text.contains(Self.literalKey))
    }

    /// A literal header of an MCP server is refused, because a header carries
    /// a token.
    @Test func aLiteralHeaderOfAnMCPServerIsRefused() async throws {
        let fixture = try SettingsGraphFixture(label: "secret-header")
        let servers: Map = [
            ["name": "remote", "url": "https://example.com/mcp", "headers": ["Authorization": .string(Self.literalKey)]]
        ]

        let reply = try await fixture.set(
            servers, at: ["tools", "mcp"], level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)

        #expect(reply.codes == [SettingsGraphError.secretNeedsReference(keyPath: "").code])
        #expect(reply.messages.first?.contains("tools.mcp.remote.headers.Authorization") == true)
        #expect(!reply.text.contains(Self.literalKey))
    }

    /// A `keychain:` reference for a secret key is accepted, and the query
    /// gives the reference and tells that the secret store has an item.
    @Test func aReferenceIsAcceptedAndTheQueryTellsIfTheStoreHasAnItem() async throws {
        let fixture = try SettingsGraphFixture(
            label: "secret-reference", secrets: [Self.referenceName: Self.secretValue])

        let set = try await fixture.set(
            .string(Self.reference), at: SettingsGraphFixture.tavilyKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)
        let reply = try await fixture.setting(SettingsGraphFixture.tavilyKeyPath, cwd: fixture.firstDirectory)

        #expect(set.codes.isEmpty)
        let setting = try reply.object("setting")
        #expect(setting["value"] as? String == Self.reference)
        let secrets = try #require(setting["secrets"] as? [[String: Any]])
        #expect(secrets.count == 1)
        #expect(secrets.first?["keyPath"] as? String == SettingsGraphFixture.tavilyDottedKeyPath)
        #expect(secrets.first?["reference"] as? String == Self.referenceName)
        #expect(secrets.first?["hasValue"] as? Bool == true)
        #expect(!reply.text.contains(Self.secretValue))
        #expect(!set.text.contains(Self.secretValue))
    }

    /// A `null` for a secret key is accepted, the same as a read keeps it: a
    /// `null` clears the key and holds no secret value. The `value` argument
    /// is `JSON!`, thus the `null` comes inside a mapping. The query then
    /// gives `null`, and the secret has no reference and no value.
    @Test func aNullForASecretKeyIsAccepted() async throws {
        let fixture = try SettingsGraphFixture(label: "secret-null")
        let tavily = try #require(SettingsGraphFixture.tavilyKeyPath.last)
        let apiKeys: Map = [tavily: .null]

        let set = try await fixture.set(
            apiKeys, at: Array(SettingsGraphFixture.tavilyKeyPath.dropLast()),
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)
        let reply = try await fixture.setting(SettingsGraphFixture.tavilyKeyPath, cwd: fixture.firstDirectory)

        #expect(set.codes.isEmpty)
        let setting = try reply.object("setting")
        #expect(setting["value"] is NSNull)
        let secrets = try #require(setting["secrets"] as? [[String: Any]])
        #expect(secrets.first?["keyPath"] as? String == SettingsGraphFixture.tavilyDottedKeyPath)
        #expect(secrets.first?["reference"] is NSNull)
        #expect(secrets.first?["hasValue"] as? Bool == false)
    }

    /// A reference whose item the secret store does not have gives
    /// `hasValue: false`.
    @Test func aReferenceWithNoItemHasNoValue() async throws {
        let fixture = try SettingsGraphFixture(label: "secret-missing")
        try await fixture.store.set(.string(Self.reference), at: SettingsGraphFixture.tavilyKeyPath, level: .user)

        let reply = try await fixture.setting(SettingsGraphFixture.tavilyKeyPath, cwd: fixture.firstDirectory)

        let secrets = try #require(try reply.object("setting")["secrets"] as? [[String: Any]])
        #expect(secrets.first?["reference"] as? String == Self.referenceName)
        #expect(secrets.first?["hasValue"] as? Bool == false)
    }

    /// A literal secret that a file holds does not go through the endpoint:
    /// the value shows the redacted form, and the secret has no reference.
    @Test func aLiteralSecretOfAFileIsNotShown() async throws {
        let fixture = try SettingsGraphFixture(label: "secret-file")
        try ConfigFileFixture.write(Self.literalYAML, in: try fixture.userRoot)

        let reply = try await fixture.setting(SettingsGraphFixture.webKeyPath, cwd: fixture.firstDirectory)

        #expect(!reply.text.contains(Self.literalKey))
        let setting = try reply.object("setting")
        let apiKeys = (setting["value"] as? [String: Any])?["apiKeys"] as? [String: Any]
        #expect(apiKeys?["tavily"] as? String == ConfiguredSecret.redactedForm)
        let secrets = try #require(setting["secrets"] as? [[String: Any]])
        #expect(secrets.first?["keyPath"] as? String == SettingsGraphFixture.tavilyDottedKeyPath)
        #expect(secrets.first?["reference"] is NSNull)
        #expect(secrets.first?["hasValue"] as? Bool == false)
    }

    // MARK: - The read after a change

    /// A `set` whose read after the change cannot read the secret store
    /// succeeds: the file holds the new reference, the result gives the
    /// reference with an unknown `hasValue` (`null`), and a warning tells
    /// that the read after the change was partial.
    @Test func aSetSucceedsWhenTheReadAfterTheChangeCannotReadASecret() async throws {
        let fixture = try SettingsGraphFixture(label: "read-back-set", secretStore: FailingSecretStore())

        let reply = try await fixture.set(
            .string(Self.reference), at: SettingsGraphFixture.tavilyKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)

        #expect(reply.codes.isEmpty)
        #expect(reply.warningCodes == [SettingsGraphResolver.readBackWarningCode])
        #expect(try textOnDisk(at: ConfigCommandFixture.configURL(in: try fixture.userRoot)).contains(Self.reference))
        let result = try reply.object("set")
        #expect(result["value"] as? String == Self.reference)
        let secrets = try #require(result["secrets"] as? [[String: Any]])
        #expect(secrets.first?["reference"] as? String == Self.referenceName)
        #expect(secrets.first?["hasValue"] is NSNull)
    }

    /// A `clear` whose read after the change cannot read the secret store
    /// succeeds: the session file loses the key, the result gives the user
    /// reference with an unknown `hasValue` (`null`), and a warning tells
    /// that the read after the change was partial.
    @Test func aClearSucceedsWhenTheReadAfterTheChangeCannotReadASecret() async throws {
        let fixture = try SettingsGraphFixture(label: "read-back-clear", secretStore: FailingSecretStore())
        try await fixture.store.set(.string(Self.reference), at: SettingsGraphFixture.tavilyKeyPath, level: .user)
        try await fixture.store.set(
            .string(Self.sessionReference), at: SettingsGraphFixture.tavilyKeyPath,
            level: .session(fixture.firstDirectory))

        let reply = try await fixture.clear(
            SettingsGraphFixture.tavilyKeyPath, level: SettingsGraphFixture.sessionLevel,
            cwd: fixture.firstDirectory)

        #expect(reply.codes.isEmpty)
        #expect(reply.warningCodes == [SettingsGraphResolver.readBackWarningCode])
        let sessionFile = ConfigCommandFixture.configURL(in: try fixture.sessionRoot(of: fixture.firstDirectory))
        #expect(try !textOnDisk(at: sessionFile).contains(Self.sessionReference))
        let result = try reply.object("clear")
        #expect(result["level"] as? String == SettingsGraphFixture.userLevel)
        let secrets = try #require(result["secrets"] as? [[String: Any]])
        #expect(secrets.first?["reference"] as? String == Self.referenceName)
        #expect(secrets.first?["hasValue"] is NSNull)
    }

    /// A `set` whose read after the change cannot read a level file
    /// succeeds: the file holds the new value, the result is `null` because
    /// each part of it is unknown, and a warning tells that the read after
    /// the change failed.
    @Test func aSetSucceedsWhenTheReadAfterTheChangeCannotReadALevel() async throws {
        let fixture = try SettingsGraphFixture(label: "read-back-level")
        try ConfigFileFixture.write(Self.brokenYAML, in: try fixture.sessionRoot(of: fixture.firstDirectory))

        let reply = try await fixture.set(
            .number(Number(Self.userTrigger)), at: SettingsGraphFixture.triggerKeyPath,
            level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)

        #expect(reply.codes.isEmpty)
        #expect(reply.warningCodes == [SettingsGraphResolver.readBackWarningCode])
        #expect(reply.data?["set"] is NSNull)
        let userFile = ConfigCommandFixture.configURL(in: try fixture.userRoot)
        #expect(try textOnDisk(at: userFile).contains("\(Self.userTrigger)"))
        let stored = try await fixture.store.value(
            at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.secondDirectory)
        #expect(stored == SettingsValue(value: .double(Self.userTrigger), level: .user))
    }

    /// The `setting` query keeps its rule: a secret that the secret store
    /// cannot read is an error.
    @Test func aQueryFailsWhenItCannotReadASecret() async throws {
        let fixture = try SettingsGraphFixture(label: "read-query", secretStore: FailingSecretStore())
        try await fixture.store.set(.string(Self.reference), at: SettingsGraphFixture.tavilyKeyPath, level: .user)

        let reply = try await fixture.setting(SettingsGraphFixture.tavilyKeyPath, cwd: fixture.firstDirectory)

        #expect(reply.codes == [SettingsGraphError.unreadableSecret(reference: "").code])
        #expect(reply.warningCodes.isEmpty)
    }
}
