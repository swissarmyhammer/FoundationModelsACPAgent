import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The `keychain:<name>` secret references of `config.yaml` (ACPA-18, D101):
/// the loader gives each reference its value from the ``SecretStore``, a
/// reference with no item gives one warning and sets no key, a literal still
/// loads, and each text form shows the reference and never the value.
///
/// Each load reads an ``InMemorySecretStore``, thus no test touches the real
/// Keychain.
@Suite struct SecretReferenceTests {
    // MARK: - Constants

    /// The reference name of the Tavily key.
    private static let referenceName = "tavily-api-key"

    /// The text that `config.yaml` holds for the Tavily key.
    private static let referenceText = "keychain:\(referenceName)"

    /// The value that the store holds for ``referenceName``.
    private static let secretValue = "secret-reference-value-7c41d2"

    /// A literal key value in `config.yaml`.
    private static let literalValue = "secret-literal-value-3f9a06"

    /// The dotted key path of the Tavily key.
    private static let keyPath = "tools.web.apiKeys.tavily"

    /// The dotted key path of the Exa key.
    private static let exaKeyPath = "tools.web.apiKeys.exa"

    /// The reference name of the Exa key, which no store of this suite holds.
    private static let missingReferenceName = "exa-api-key"

    /// The environment variable of the Tavily provider.
    private static let tavilyVariable = "TAVILY_API_KEY"

    /// A key value that the process environment holds.
    private static let environmentValue = "secret-environment-value-a0b5e8"

    /// A project `config.yaml` with the Tavily key as a reference.
    private static let referenceYAML = "tools:\n  web:\n    apiKeys:\n      tavily: \(referenceText)\n"

    /// A project `config.yaml` with the Tavily key as a literal.
    private static let literalYAML = "tools:\n  web:\n    apiKeys:\n      tavily: \(literalValue)\n"

    /// A project `config.yaml` with the Tavily reference, which the store
    /// holds, and the Exa reference, which no store holds.
    private static let mixedYAML =
        "tools:\n  web:\n    apiKeys:\n      tavily: \(referenceText)\n      exa: keychain:\(missingReferenceName)\n"

    /// The store that holds the value of ``referenceName``.
    private static let storeWithItem = InMemorySecretStore([referenceName: secretValue])

    /// The text of the warning for a reference with no item.
    private static let noItemText = "has no item"

    /// The text of the warning for a reference whose lookup failed.
    private static let lookupFailedText = "could not read"

    // MARK: - Helpers

    /// Loads `yaml` as the project `config.yaml` over `store`.
    ///
    /// - Parameters:
    ///   - yaml: The project `config.yaml`.
    ///   - store: The store of the load.
    /// - Returns: The load.
    /// - Throws: Whatever the load throws.
    private static func load(_ yaml: String, store: any SecretStore) throws -> LoadedConfiguration {
        try ConfigurationLoaderTests.Fixture().loadProjectConfig(yaml, secretStore: store)
    }

    /// The web options of `loaded`.
    ///
    /// - Parameter loaded: The load.
    /// - Returns: The options of the mounted web tool.
    /// - Throws: A failed requirement when the web tool is off.
    private static func webOptions(of loaded: LoadedConfiguration) throws -> WebToolOptions {
        try #require(loaded.configuration.tools.web.mountedOptions)
    }

    // MARK: - The load

    /// A reference with an item gives the value to the environment of the
    /// web tool, and the load gives no warning.
    @Test func aReferenceWithAnItemGivesTheValueToTheWebEnvironment() throws {
        let loaded = try Self.load(Self.referenceYAML, store: Self.storeWithItem)

        let options = try Self.webOptions(of: loaded)
        #expect(options.environment(mergedOver: [:])[Self.tavilyVariable] == Self.secretValue)
        #expect(options.apiKeys[.tavily]?.reference == Self.referenceName)
        #expect(loaded.warnings.isEmpty)
    }

    /// A reference with no item gives one warning that names the key path and
    /// the reference, and the key is not set.
    @Test func aReferenceWithNoItemGivesOneWarningAndSetsNoKey() throws {
        let loaded = try Self.load(Self.referenceYAML, store: InMemorySecretStore())

        let options = try Self.webOptions(of: loaded)
        #expect(loaded.warnings == [.unresolvedSecret(keyPath: Self.keyPath, reference: Self.referenceName)])
        #expect(options.apiKeys[.tavily] == nil)
        #expect(options.environment(mergedOver: [:])[Self.tavilyVariable] == nil)
        let message = try #require(loaded.warnings.first).description
        #expect(message.contains(Self.keyPath))
        #expect(message.contains(Self.referenceName))
        #expect(message.contains(Self.noItemText))
    }

    /// A store that throws gives one warning that says the lookup failed,
    /// and the key is not set. The warning does not say that the item is
    /// missing, and it names only the key path and the reference.
    @Test func aStoreFailureGivesOneLookupFailedWarningAndSetsNoKey() throws {
        let loaded = try Self.load(Self.referenceYAML, store: FailingSecretStore())

        #expect(loaded.warnings == [.unreadableSecret(keyPath: Self.keyPath, reference: Self.referenceName)])
        #expect(try Self.webOptions(of: loaded).apiKeys[.tavily] == nil)
        let message = try #require(loaded.warnings.first).description
        #expect(message.contains(Self.lookupFailedText))
        #expect(!message.contains(Self.noItemText))
        #expect(message.contains(Self.keyPath))
        #expect(message.contains(Self.referenceName))
    }

    /// A literal key still loads, with no reference.
    @Test func aLiteralKeyStillLoads() throws {
        let loaded = try Self.load(Self.literalYAML, store: InMemorySecretStore())

        let options = try Self.webOptions(of: loaded)
        #expect(options.apiKeys[.tavily] == ConfiguredSecret(Self.literalValue))
        #expect(options.apiKeys[.tavily]?.reference == nil)
        #expect(options.environment(mergedOver: [:])[Self.tavilyVariable] == Self.literalValue)
        #expect(loaded.warnings.isEmpty)
    }

    /// A reference that has no value yet puts nothing into the environment:
    /// the variable of the process environment stays, and no empty key
    /// takes its place.
    @Test func anUnresolvedReferencePutsNothingIntoTheEnvironment() {
        let options = WebToolOptions(apiKeys: [.tavily: ConfiguredSecret(reference: Self.referenceName)])

        let environment = options.environment(mergedOver: [Self.tavilyVariable: Self.environmentValue])

        #expect(environment[Self.tavilyVariable] == Self.environmentValue)
    }

    // MARK: - The text forms

    /// Each form of the document encodes a reference as `keychain:<name>`,
    /// and never as the value.
    @Test(arguments: [ConfigurationYAML.SecretForm.redacted, .omitted])
    func eachSecretFormEncodesTheReference(form: ConfigurationYAML.SecretForm) throws {
        let loaded = try Self.load(Self.referenceYAML, store: Self.storeWithItem)

        let yaml = try ConfigurationYAML.documentText(for: loaded.configuration, secrets: form)

        #expect(yaml.contains("tavily: \"\(Self.referenceText)\""))
        #expect(!yaml.contains(Self.secretValue))
    }

    /// The document that a writer puts in a layer keeps no literal key: the
    /// `omitted` form drops a literal and keeps a reference.
    @Test func theOmittedFormKeepsAReferenceAndDropsALiteral() throws {
        let options = WebToolOptions(apiKeys: [
            .tavily: ConfiguredSecret(reference: Self.referenceName),
            .exa: ConfiguredSecret(Self.literalValue),
        ])
        var configuration = AgentConfiguration()
        configuration.tools.web = .enabled(options)

        let yaml = try ConfigurationYAML.documentText(for: configuration, secrets: .omitted)

        #expect(yaml.contains("tavily: \"\(Self.referenceText)\""))
        #expect(!yaml.contains("exa:"))
        #expect(!yaml.contains(Self.literalValue))
    }

    /// The JSON form encodes a reference as `keychain:<name>`.
    @Test func theJSONFormEncodesTheReference() throws {
        let loaded = try Self.load(Self.referenceYAML, store: Self.storeWithItem)

        let json = String(decoding: try JSONEncoder().encode(loaded.configuration), as: UTF8.self)

        #expect(json.contains(Self.referenceText))
        #expect(!json.contains(Self.secretValue))
    }

    /// `description`, `debugDescription` and the mirror of a reference show
    /// `keychain:<name>`, and never the value.
    @Test func aReferenceShowsItsReferenceInEachTextForm() throws {
        let loaded = try Self.load(Self.referenceYAML, store: Self.storeWithItem)
        let secret = try #require(try Self.webOptions(of: loaded).apiKeys[.tavily])

        let mirrored = Mirror(reflecting: secret).children.map { String(describing: $0.value) }

        #expect(String(describing: secret) == Self.referenceText)
        #expect(String(reflecting: secret) == Self.referenceText)
        #expect(mirrored == [Self.referenceText])
    }

    // MARK: - The log

    /// The warning of a reference with no item writes one `warning` record
    /// with the key path in its metadata, and no record holds a value.
    @Test func theWarningLogRecordHoldsTheKeyPathAndNoValue() async throws {
        let records = try await TelemetryCapture.run(forbidding: [Self.secretValue]) { context in
            _ = try Self.load(Self.mixedYAML, store: Self.storeWithItem)
            return context.logRecords
        }

        let sectionKey = ACPAgentTelemetry.LogMetadataKey.configSection
        let sectionRecords = records.filter { $0.metadata[sectionKey] != nil }
        #expect(sectionRecords.count == 1)
        let record = try #require(sectionRecords.first)
        #expect(record.level == .warning)
        #expect(record.metadata[sectionKey] == .string(Self.exaKeyPath))
    }
}
