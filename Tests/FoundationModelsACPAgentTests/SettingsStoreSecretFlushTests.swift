import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The flush of `SettingsStore` and the secrets of a level file (ACPA-18,
/// D101(c)): a `keychain:<name>` reference stays a reference, a literal
/// stays the text that the user typed in that file, no literal goes into
/// the file of another level or into a change event, and no flush writes a
/// value from the secret store.
///
/// Each test reads the file after each flush. Each test uses the temporary
/// folders of ``SettingsStoreTests/Fixture`` and an ``InMemorySecretStore``,
/// thus no test reads the real home directory or the real Keychain.
@Suite struct SettingsStoreSecretFlushTests {
    // MARK: - Constants

    /// The key path of `compaction.trigger`, the key that each change sets
    /// or clears.
    private static let triggerKeyPath = ["compaction", "trigger"]

    /// The key path of the section that holds each secret of the files.
    private static let toolsKeyPath = ["tools"]

    /// The values of `compaction.trigger` that the flushes set, one for each
    /// `set`.
    private static let triggers = [0.7, 0.9]

    /// The reference name of each web API key that the user file gives as
    /// a `keychain:` reference.
    private static let webReferences: [WebAPIKeyName: String] = [
        .brave: "brave-api-key",
        .tavily: "tavily-api-key",
        .exa: "exa-api-key",
    ]

    /// The literal text of each web API key that the user file gives as a
    /// literal.
    private static let webLiterals: [WebAPIKeyName: String] = [
        .serper: "serper-literal-key-4a91d0",
        .kagi: "kagi-literal-key-7c22e5",
        .searxngURL: "https://searxng.example.test",
    ]

    /// The reference name of the MCP header token.
    private static let headerReference = "github-mcp-token"

    /// The reference name of the MCP env token.
    private static let envReference = "github-token"

    /// A literal MCP header value in the session file.
    private static let literalHeaderValue = "mcp-literal-header-value-3b07f9"

    /// A literal MCP env value in the session file.
    private static let literalEnvValue = "mcp-literal-env-value-e6d158"

    /// The value that the secret store holds for each reference name of
    /// the files. No flush may write one of these values.
    private static let storeValues: [String: String] = [
        "brave-api-key": "brave-keychain-value-11f3a2",
        "tavily-api-key": "tavily-keychain-value-52c8e0",
        "exa-api-key": "exa-keychain-value-9d4b71",
        headerReference: "mcp-header-keychain-value-08e6c3",
        envReference: "mcp-env-keychain-value-6fa21d",
    ]

    /// A user `config.yaml` with each web API key: three references and
    /// three literals.
    private static let webKeysYAML: String = {
        let references = WebAPIKeyName.allCases.compactMap { name in
            webReferences[name].map { "      \(name.rawValue): keychain:\($0)" }
        }
        let literals = WebAPIKeyName.allCases.compactMap { name in
            webLiterals[name].map { "      \(name.rawValue): \($0)" }
        }
        return (["tools:", "  web:", "    apiKeys:"] + references + literals).joined(separator: "\n") + "\n"
    }()

    /// A session `config.yaml` with one http MCP server and one stdio MCP
    /// server. Each server has one reference and one literal.
    private static let mcpServersYAML = """
        tools:
          mcp:
            - name: github-remote
              url: https://example.test/mcp
              headers:
                Authorization: keychain:\(headerReference)
                X-Api-Key: \(literalHeaderValue)
            - name: github-local
              command: /usr/local/bin/github-mcp
              env:
                GITHUB_TOKEN: keychain:\(envReference)
                GITHUB_HOST: \(literalEnvValue)

        """

    /// Each literal secret of the files.
    private static var literalValues: [String] {
        Array(webLiterals.values) + [literalHeaderValue, literalEnvValue]
    }

    // MARK: - Helpers

    /// Makes a fixture whose secret store holds ``storeValues``.
    ///
    /// - Parameter label: The prefix that names the test.
    /// - Returns: The fixture.
    /// - Throws: What ``SettingsStoreTests/Fixture/init(label:secretStore:)``
    ///   throws.
    private static func makeFixture(label: String) throws -> SettingsStoreTests.Fixture {
        try SettingsStoreTests.Fixture(
            label: "secret-flush-\(label)", secretStore: InMemorySecretStore(storeValues))
    }

    /// Makes three flushes of `level`: two `set` calls and one `clear` of
    /// `compaction.trigger`. After each flush, it reads the file of the level
    /// and checks the secrets in it.
    ///
    /// - Parameters:
    ///   - store: The store that flushes.
    ///   - level: The level to change.
    ///   - file: The `config.yaml` of the level.
    ///   - yaml: The text that the file had before the first flush.
    ///   - references: The reference name of each `keychain:` reference in
    ///     `yaml`.
    /// - Throws: What a flush or a read of the file throws.
    private static func flushAndCheck(
        _ store: SettingsStore, level: SettingsLevel, file: URL, yaml: String, references: [String]
    ) async throws {
        let secrets = try YAMLValue.parse(yaml).value(at: toolsKeyPath)
        for trigger in triggers {
            try await store.set(.double(trigger), at: triggerKeyPath, level: level)
            try expectSecretsKept(in: file, as: secrets, references: references)
        }
        try await store.clear(at: triggerKeyPath, level: level)
        try expectSecretsKept(in: file, as: secrets, references: references)
    }

    /// Checks the text of a `config.yaml` after a flush: the `tools` section
    /// is the section that the file had, each reference is still
    /// `keychain:<name>`, and the file holds no value of the secret store.
    ///
    /// - Parameters:
    ///   - file: The `config.yaml` to read.
    ///   - secrets: The `tools` section that the file had before the flush.
    ///   - references: The reference name of each `keychain:` reference that
    ///     the file must still hold.
    /// - Throws: What a read or a parse of the file throws.
    private static func expectSecretsKept(in file: URL, as secrets: YAMLValue?, references: [String]) throws {
        let text = try textOnDisk(at: file)
        #expect(try YAMLValue.parse(text).value(at: toolsKeyPath) == secrets)
        for value in storeValues.values {
            #expect(!text.contains(value))
        }
        for name in references {
            #expect(text.contains(ConfiguredSecret.referencePrefix + name))
        }
    }

    // MARK: - Tests

    /// After each flush of the user level, each web API key reference stays
    /// `keychain:<name>`, each literal key stays the text of the file, and
    /// the file holds no value of the secret store. The literals still load.
    @Test func eachUserFlushKeepsTheWebAPIKeys() async throws {
        let fixture = try Self.makeFixture(label: "web")
        let userFile = ConfigCommandFixture.configURL(in: try fixture.userRoot)
        try ConfigFileFixture.write(Self.webKeysYAML, in: try fixture.userRoot)

        try await Self.flushAndCheck(
            fixture.store, level: .user, file: userFile, yaml: Self.webKeysYAML,
            references: Array(Self.webReferences.values))

        let merged = try await fixture.store.merged(for: fixture.firstDirectory)
        let options = try #require(merged.configuration.tools.web.mountedOptions)
        for (name, literal) in Self.webLiterals {
            #expect(options.apiKeys[name]?.value == literal)
        }
        for (name, reference) in Self.webReferences {
            #expect(options.apiKeys[name]?.reference == reference)
        }
    }

    /// After each flush of a session level, each MCP header and env
    /// reference stays `keychain:<name>`, each literal header and env value
    /// stays the text of the file, and the file holds no value of the secret
    /// store.
    @Test func eachSessionFlushKeepsTheMCPHeadersAndEnv() async throws {
        let fixture = try Self.makeFixture(label: "mcp")
        let sessionRoot = try fixture.sessionRoot(of: fixture.firstDirectory)
        try ConfigFileFixture.write(Self.mcpServersYAML, in: sessionRoot)

        try await Self.flushAndCheck(
            fixture.store, level: .session(fixture.firstDirectory),
            file: ConfigCommandFixture.configURL(in: sessionRoot), yaml: Self.mcpServersYAML,
            references: [Self.headerReference, Self.envReference])
    }

    /// A flush of a session level writes no literal and no reference of the
    /// user level into the session file, and does not change the user file.
    @Test func aSessionFlushMovesNoSecretFromTheUserLevel() async throws {
        let fixture = try Self.makeFixture(label: "levels")
        let userFile = ConfigCommandFixture.configURL(in: try fixture.userRoot)
        let sessionFile = ConfigCommandFixture.configURL(in: try fixture.sessionRoot(of: fixture.firstDirectory))
        try ConfigFileFixture.write(Self.webKeysYAML, in: try fixture.userRoot)

        try await fixture.store.set(
            .double(Self.triggers[0]), at: Self.triggerKeyPath, level: .session(fixture.firstDirectory))

        let sessionText = try textOnDisk(at: sessionFile)
        for literal in Self.literalValues {
            #expect(!sessionText.contains(literal))
        }
        #expect(!sessionText.contains(ConfiguredSecret.referencePrefix))
        #expect(try YAMLValue.parse(sessionText).value(at: Self.toolsKeyPath) == nil)
        #expect(try textOnDisk(at: userFile) == Self.webKeysYAML)
    }

    /// The change event of a flush of a level with secrets names the level
    /// and the key path, and holds no literal and no value of the secret
    /// store.
    @Test(.timeLimit(.minutes(1))) func aChangeEventHoldsNoSecret() async throws {
        let fixture = try Self.makeFixture(label: "change")
        try ConfigFileFixture.write(Self.webKeysYAML, in: try fixture.userRoot)
        var changes = await fixture.store.changes().makeAsyncIterator()

        try await fixture.store.set(.double(Self.triggers[0]), at: Self.triggerKeyPath, level: .user)

        let change = try #require(await changes.next())
        #expect(change == SettingsChange(level: .user, keyPath: Self.triggerKeyPath))
        let shown = String(describing: change)
        for secret in Self.literalValues + Array(Self.storeValues.values) {
            #expect(!shown.contains(secret))
        }
    }
}
