import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// `SettingsTool` (ACPA-17, D75): the model tool over the same engine as the
/// `settings` endpoint. It gives the endpoint through `GraphQLEndpointTool`,
/// and one operation through `OperationDescribing` for Multitool.
@Suite struct SettingsToolTests {
    /// The value of `compaction.trigger` that the user level sets.
    private static let userTrigger = 0.7

    /// The value of `compaction.trigger` that a session level sets.
    private static let sessionTrigger = 0.9

    /// The noun that a host gives to the tool in Multitool.
    private static let noun = "settings"

    /// An operation that the tool does not have.
    private static let unknownOperation = "drop settings"

    /// A tool over the store of `fixture`.
    ///
    /// - Parameter fixture: The fixture that holds the store.
    /// - Returns: The tool.
    /// - Throws: The error of the schema build.
    private static func tool(over fixture: SettingsGraphFixture) throws -> SettingsTool {
        try SettingsTool(store: fixture.store)
    }

    /// The arguments of a `set` call.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - level: The `SettingLevel` name.
    ///   - workingDirectory: The working directory of the session.
    /// - Returns: The arguments.
    private static func setArguments(_ value: Double, level: String, cwd workingDirectory: URL) -> GraphQLArguments {
        var variables = SettingsGraphFixture.variables(keyPath: SettingsGraphFixture.triggerKeyPath, cwd: workingDirectory)
        variables["value"] = .number(Number(value))
        variables["level"] = .string(level)
        return GraphQLArguments(query: SettingsGraphFixture.setMutation, variables: variables)
    }

    /// The tool gives one endpoint: the `settings` endpoint.
    @Test func theToolGivesTheSettingsEndpoint() throws {
        let fixture = try SettingsGraphFixture(label: "tool-endpoint")

        let endpoints = try Self.tool(over: fixture).graphQLEndpoints

        #expect(endpoints.map(\.name) == [SettingsGraph.endpointName])
        #expect(endpoints.first?.scope == .server)
    }

    /// A `set` on each level and a `clear` on the session level
    /// work through the tool, and the store has each change.
    @Test func eachLevelChangesThroughTheTool() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-levels")
        let tool = try Self.tool(over: fixture)

        let user = try GraphQLReply(
            await tool.call(
                arguments: Self.setArguments(
                    Self.userTrigger, level: SettingsGraphFixture.userLevel, cwd: fixture.firstDirectory)))
        let sessionSet = try GraphQLReply(
            await tool.call(
                arguments: Self.setArguments(
                    Self.sessionTrigger, level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)))
        let sessionValue = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
        var clearVariables = SettingsGraphFixture.variables(
            keyPath: SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
        clearVariables["level"] = .string(SettingsGraphFixture.sessionLevel)
        let clear = try GraphQLReply(
            await tool.call(
                arguments: GraphQLArguments(query: SettingsGraphFixture.clearMutation, variables: clearVariables)))

        #expect(user.codes.isEmpty)
        #expect(sessionSet.codes.isEmpty)
        #expect(clear.codes.isEmpty)
        #expect(sessionValue == SettingsValue(value: .double(Self.sessionTrigger), level: .project))
        let restored = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
        #expect(restored == SettingsValue(value: .double(Self.userTrigger), level: .user))
        #expect(try clear.object("clear")["level"] as? String == SettingsGraphFixture.userLevel)
    }

    /// The tool does not run a subscription.
    @Test func theToolRefusesASubscription() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-subscription")

        let reply = try GraphQLReply(
            await Self.tool(over: fixture).call(
                arguments: GraphQLArguments(
                    query: SettingsGraphFixture.changesSubscription,
                    variables: ["cwd": .string(fixture.firstDirectory.path)])))

        #expect(reply.codes == [GraphQLToolkitError.subscriptionNotInTool(hint: nil).code])
    }

    /// The tool describes one operation, `query settings`, whose parameters
    /// are the parts of a GraphQL call.
    @Test func theToolDescribesOneOperation() throws {
        let fixture = try SettingsGraphFixture(label: "tool-descriptors")

        let descriptors = try Self.tool(over: fixture).operationDescriptors

        #expect(descriptors.map(\.opString) == [SettingsTool.queryOperation])
        #expect(descriptors.first?.parameters.map(\.name) == ["query", "variables", "operationName"])
        #expect(descriptors.first?.parameters.first?.required == true)
    }

    /// `perform(_:)` runs the document of an `op` payload over the same
    /// engine.
    @Test func performRunsTheDocument() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-perform")
        try await fixture.store.set(.double(Self.userTrigger), at: SettingsGraphFixture.triggerKeyPath, level: .user)
        let payload = GeneratedContent(
            properties: [
                "op": SettingsTool.queryOperation,
                "query": "{ setting(keyPath: [\"compaction\", \"trigger\"], cwd: \"\(fixture.firstDirectory.path)\") { value level } }",
            ])

        let reply = try GraphQLReply(await Self.tool(over: fixture).perform(payload))

        let setting = try reply.object("setting")
        #expect(setting["value"] as? Double == Self.userTrigger)
        #expect(setting["level"] as? String == SettingsGraphFixture.userLevel)
    }

    /// `perform(_:)` throws for an operation that the tool does not have.
    @Test func performRefusesAnUnknownOperation() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-unknown")
        let payload = GeneratedContent(properties: ["op": Self.unknownOperation, "query": "{ sections }"])

        await #expect(throws: SettingsToolError.unknownOperation(Self.unknownOperation)) {
            try await Self.tool(over: fixture).perform(payload)
        }
    }

    // MARK: - The session folder

    /// A tool of the session whose folder is the first directory of
    /// `fixture`.
    ///
    /// - Parameter fixture: The fixture that holds the store.
    /// - Returns: The tool.
    /// - Throws: The error of the schema build.
    private static func sessionTool(over fixture: SettingsGraphFixture) throws -> SettingsTool {
        try SettingsTool(store: fixture.store, sessionDirectory: fixture.firstDirectory)
    }

    /// The arguments of a `set` call on the session level with no `cwd`.
    ///
    /// - Parameter value: The new value.
    /// - Returns: The arguments.
    private static func sessionSetArguments(_ value: Double) -> GraphQLArguments {
        GraphQLArguments(
            query: SettingsGraphFixture.sessionSetMutation,
            variables: [
                "keyPath": .array(SettingsGraphFixture.triggerKeyPath.map(Map.string)),
                "value": .number(Number(value)),
                "level": .string(SettingsGraphFixture.sessionLevel),
            ])
    }

    /// A query with no `cwd` gives the merged value for the session folder of
    /// the tool.
    @Test func aSessionToolReadsTheSettingOfItsSessionFolder() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-session-read")
        try await fixture.store.set(.double(Self.userTrigger), at: SettingsGraphFixture.triggerKeyPath, level: .user)
        try await fixture.store.set(
            .double(Self.sessionTrigger), at: SettingsGraphFixture.triggerKeyPath,
            level: .session(fixture.firstDirectory))

        let reply = try GraphQLReply(
            await Self.sessionTool(over: fixture).call(
                arguments: GraphQLArguments(
                    query: SettingsGraphFixture.sessionSettingQuery,
                    variables: ["keyPath": .array(SettingsGraphFixture.triggerKeyPath.map(Map.string))])))

        let setting = try reply.object("setting")
        #expect(setting["value"] as? Double == Self.sessionTrigger)
        #expect(setting["level"] as? String == SettingsGraphFixture.sessionLevel)
    }

    /// A `set` on the session level with no `cwd` writes the level of the
    /// session folder of the tool, and no other folder.
    @Test func aSessionToolWritesTheSessionLevelOfItsSessionFolder() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-session-write")

        let reply = try GraphQLReply(
            await Self.sessionTool(over: fixture).call(arguments: Self.sessionSetArguments(Self.sessionTrigger)))

        #expect(reply.codes.isEmpty)
        let session = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
        #expect(session == SettingsValue(value: .double(Self.sessionTrigger), level: .project))
        let other = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.secondDirectory)
        #expect(other?.level != .project)
    }

    /// A session tool refuses a `cwd` that is not its session folder, and
    /// the level of that folder does not change.
    @Test func aSessionToolRefusesTheFolderOfAnOtherSession() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-session-other")

        let reply = try GraphQLReply(
            await Self.sessionTool(over: fixture).call(
                arguments: Self.setArguments(
                    Self.sessionTrigger, level: SettingsGraphFixture.sessionLevel, cwd: fixture.secondDirectory)))

        #expect(reply.codes == [SettingsGraphError.otherSessionWorkingDirectory(path: "").code])
        let other = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.secondDirectory)
        #expect(other?.level != .project)
    }

    /// A session tool takes a `cwd` that names its own session folder.
    @Test func aSessionToolTakesItsOwnSessionFolder() async throws {
        let fixture = try SettingsGraphFixture(label: "tool-session-own")

        let reply = try GraphQLReply(
            await Self.sessionTool(over: fixture).call(
                arguments: Self.setArguments(
                    Self.sessionTrigger, level: SettingsGraphFixture.sessionLevel, cwd: fixture.firstDirectory)))

        #expect(reply.codes.isEmpty)
        let session = try await fixture.store.value(at: SettingsGraphFixture.triggerKeyPath, cwd: fixture.firstDirectory)
        #expect(session == SettingsValue(value: .double(Self.sessionTrigger), level: .project))
    }

    /// Multitool mounts the tool under a noun that the host gives.
    @Test func multitoolMountsTheTool() throws {
        let fixture = try SettingsGraphFixture(label: "tool-multitool")

        #expect(throws: Never.self) {
            try MultiTool.Builder().withOperationTool(noun: Self.noun, tool: try Self.tool(over: fixture))
                .buildRegistry()
        }
    }
}
