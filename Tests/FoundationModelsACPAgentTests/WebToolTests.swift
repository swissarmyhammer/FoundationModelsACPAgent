import Foundation
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The `tools.web:` section (task ^ba231ka): the codec of its two keys, the
/// provider order that the configuration and the environment give, and the
/// redaction of each key value.
///
/// No test sends a request. The provider order is read from the
/// `WebConfiguration` that the composition makes, and a key is read through
/// `WebAPIKey.resolve(in:)` of that configuration's environment.
@Suite struct WebToolTests {
    // MARK: - Constants

    /// The provider order with no key: the two keyless providers.
    private static let keylessOrder = ["braveHTML", "duckDuckGoHTML"]

    /// A key value that the environment holds.
    private static let environmentKey = "environment-key-value"

    /// A key value that the configuration holds.
    private static let configuredKey = "configured-key-value"

    /// The `tools.web.apiKeys` names in the provider table order.
    private static let validKeyNames = ["brave", "tavily", "exa", "serper", "kagi", "searxngURL"]

    // MARK: - Helpers

    /// The provider names of the configuration that the composition makes.
    ///
    /// - Parameters:
    ///   - options: The decoded web options.
    ///   - environment: The process environment.
    /// - Returns: The provider names, in the order to try.
    private static func providerNames(
        options: WebToolOptions = WebToolOptions(), environment: [String: String] = [:]
    ) -> [String] {
        WebComposition.configuration(options: options, processEnvironment: environment)
            .providers.map(\.name)
    }

    // MARK: - The codec

    /// With no `tools:` section, the web tool is on, with no key.
    @Test func noToolsSectionEnablesTheWebTool() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig("recording:\n  level: full\n")

        #expect(loaded.configuration.tools.web == .enabled(WebToolOptions()))
        #expect(loaded.configuration.tools.web.mountedOptions == WebToolOptions())
    }

    /// `enabled: false` and a scalar `false` each turn the web tool off.
    @Test(arguments: ["web:\n    enabled: false", "web: false"])
    func eachOffShapeMountsNoWebTool(body: String) throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig("tools:\n  \(body)\n")

        #expect(loaded.configuration.tools.web.mountedOptions == nil)
    }

    /// The `apiKeys` map decodes each provider key name.
    @Test func theAPIKeysMapDecodesEachKeyName() throws {
        let loaded = try ConfigurationLoaderTests.Fixture().loadProjectConfig(
            """
            tools:
              web:
                apiKeys:
                  tavily: \(Self.configuredKey)
                  searxngURL: https://search.example.com
            """)

        let expected = WebToolOptions(apiKeys: [
            .tavily: ConfiguredSecret(Self.configuredKey),
            .searxngURL: ConfiguredSecret("https://search.example.com"),
        ])
        #expect(loaded.configuration.tools.web == .enabled(expected))
    }

    /// An unknown key under `apiKeys` is a configuration error that names
    /// the valid keys.
    @Test func anUnknownAPIKeyNameIsAnErrorThatNamesTheValidKeys() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        let error = #expect(throws: ConfigurationError.self) {
            try fixture.loadProjectConfig("tools:\n  web:\n    apiKeys:\n      bing: x\n")
        }

        #expect(
            error
                == .unknownMapKey(
                    section: "tools.web.apiKeys", key: "bing", validKeys: Self.validKeyNames))
        let message = String(describing: try #require(error))
        for name in Self.validKeyNames {
            #expect(message.contains(name))
        }
    }

    /// An unknown key in the web body is an error, as in each other tool
    /// body.
    @Test func anUnknownKeyInTheWebBodyIsAnError() throws {
        let fixture = ConfigurationLoaderTests.Fixture()

        #expect(throws: ConfigurationError.unknownKey(section: "tools.web", key: "providers")) {
            try fixture.loadProjectConfig("tools:\n  web:\n    providers: []\n")
        }
    }

    /// Each key name maps to the variable of Multitool's provider table.
    @Test func eachKeyNameMapsToItsEnvironmentVariable() {
        let variables = WebAPIKeyName.allCases.map(\.environmentVariable)

        #expect(
            variables == [
                "BRAVE_SEARCH_API_KEY", "TAVILY_API_KEY", "EXA_API_KEY", "SERPER_API_KEY", "KAGI_API_KEY",
                "SEARXNG_URL",
            ])
    }

    // MARK: - The provider order

    /// No configuration and an empty environment give the keyless
    /// providers.
    @Test func noKeyGivesTheKeylessProviders() {
        #expect(Self.providerNames() == Self.keylessOrder)
    }

    /// A key in the process environment puts its provider first.
    @Test func anEnvironmentKeySelectsItsProviderFirst() {
        let names = Self.providerNames(environment: ["TAVILY_API_KEY": Self.environmentKey])

        #expect(names == ["tavily"] + Self.keylessOrder)
    }

    /// A key in the configuration puts its provider first.
    @Test func aConfiguredKeySelectsItsProviderFirst() {
        let options = WebToolOptions(apiKeys: [.exa: ConfiguredSecret(Self.configuredKey)])

        #expect(Self.providerNames(options: options) == ["exa"] + Self.keylessOrder)
    }

    /// A configured key wins over the process environment for the same
    /// variable.
    @Test func aConfiguredKeyWinsOverTheEnvironment() throws {
        let options = WebToolOptions(apiKeys: [.exa: ConfiguredSecret(Self.configuredKey)])

        let configuration = WebComposition.configuration(
            options: options, processEnvironment: ["EXA_API_KEY": Self.environmentKey])

        let exaKeys = configuration.providers.compactMap { provider -> WebAPIKey? in
            if case .exa(let key) = provider { return key }
            return nil
        }

        #expect(configuration.providers.first?.name == "exa")
        let key = try #require(exaKeys.first)
        #expect(key.resolve(in: configuration.environment) == Self.configuredKey)
    }

    /// The provider names in force: the order when the tool mounts, and
    /// `nil` when it is off.
    @Test func theProviderNamesInForceFollowTheSection() {
        let on = WebComposition.providerNames(
            section: .enabled(WebToolOptions()), processEnvironment: [:])
        let off = WebComposition.providerNames(
            section: .enabled(WebToolOptions(enabled: false)), processEnvironment: [:])

        #expect(on == Self.keylessOrder)
        #expect(off == nil)
    }

    // MARK: - Redaction

    /// No string form of a configured key shows the value.
    @Test func aConfiguredSecretShowsNoValue() {
        let secret = ConfiguredSecret(Self.configuredKey)
        var dumped = ""
        dump(WebToolOptions(apiKeys: [.kagi: secret]), to: &dumped)

        #expect(String(describing: secret) == ConfiguredSecret.redactedForm)
        #expect(String(reflecting: secret) == ConfiguredSecret.redactedForm)
        #expect(!String(describing: WebToolOptions(apiKeys: [.kagi: secret])).contains(Self.configuredKey))
        #expect(!dumped.contains(Self.configuredKey))
    }

    /// The encoded configuration holds the redacted form, and never the
    /// key value.
    @Test func theEncodedConfigurationHoldsNoKeyValue() throws {
        var configuration = AgentConfiguration()
        configuration.tools.web = .enabled(
            WebToolOptions(apiKeys: [.tavily: ConfiguredSecret(Self.configuredKey)]))

        let json = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        let yaml = try ConfigurationYAML.documentText(for: configuration)

        #expect(!json.contains(Self.configuredKey))
        #expect(!yaml.contains(Self.configuredKey))
        #expect(yaml.contains("tavily: \"\(ConfiguredSecret.redactedForm)\""))
    }

    /// The text that a writer puts in a layer holds no key at all, so a
    /// layer below keeps its keys.
    @Test func theWrittenDocumentOmitsTheKeys() throws {
        var configuration = AgentConfiguration()
        configuration.tools.web = .enabled(
            WebToolOptions(apiKeys: [.tavily: ConfiguredSecret(Self.configuredKey)]))

        let yaml = try ConfigurationYAML.documentText(for: configuration, secrets: .omitted)

        #expect(!yaml.contains(Self.configuredKey))
        #expect(!yaml.contains(ConfiguredSecret.redactedForm))
        #expect(yaml.contains("apiKeys: {}"))
    }
}
