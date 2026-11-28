import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The reasoning effort levels of the `models` endpoint (D218): each model
/// that a load on this machine probed gives its levels, its default level
/// and its Off flag, and each profile gives the levels of its `standard`
/// model. The levels come from ``ReasoningEffortLevelsRecord``.
@Suite struct ModelsGraphReasoningEffortTests {
  /// The levels of the fake standard model. The default is `medium`.
  private static let threeLevels = ReasoningEffortLevels(
    levels: ["low", "medium", "high"], defaultLevel: "medium", hasOff: true)

  /// The selection set of the reasoning effort of a model.
  private static let effortFields = "reasoningEffort { levels defaultLevel hasOff sessionLevels }"

  /// A record in a new folder of the test.
  ///
  /// - Parameter label: The label of the folder.
  /// - Returns: The record. Its file does not exist yet.
  private static func makeRecord(label: String) -> ReasoningEffortLevelsRecord {
    ReasoningEffortLevelsRecord(
      fileURL: makeResolvedDirectory(label: "ModelsEffort-\(label)")
        .appendingPathComponent("levels.json", isDirectory: false))
  }

  /// An endpoint over a settings fixture and a record with the levels of
  /// the bundled standard model.
  ///
  /// - Parameter label: The label of the test.
  /// - Returns: The endpoint.
  /// - Throws: The error of the fixture.
  private static func makeGraph(label: String) throws -> ModelsGraph {
    let fixture = try SettingsGraphFixture(label: "models-effort-\(label)")
    let record = makeRecord(label: label)
    record.record([ModelsGraphTests.standard.stringValue: threeLevels])
    return ModelsGraph(
      store: fixture.store, storage: ModelsGraphTests.builtinStorage(), effortLevels: record)
  }

  /// The reasoning effort object of a row.
  ///
  /// - Parameter row: The row.
  /// - Returns: The object.
  /// - Throws: A failed requirement when the row has no object.
  private static func effort(of row: [String: Any]) throws -> [String: Any] {
    try #require(row["reasoningEffort"] as? [String: Any], "\(row)")
  }

  // MARK: - The record

  /// A record with no file gives no levels.
  @Test func aRecordWithNoFileGivesNoLevels() {
    #expect(Self.makeRecord(label: "empty").levels().isEmpty)
  }

  /// A recorded model gives its levels back.
  @Test func aRecordGivesTheLevelsBack() {
    let record = Self.makeRecord(label: "round-trip")

    record.record(["owner/model": Self.threeLevels])

    #expect(record.levels() == ["owner/model": Self.threeLevels])
  }

  /// A second record keeps the levels of the models of the first one.
  @Test func aSecondRecordKeepsTheOtherModels() {
    let record = Self.makeRecord(label: "merge")

    record.record(["owner/first": Self.threeLevels])
    record.record(["owner/second": .unsupported])

    #expect(record.levels() == ["owner/first": Self.threeLevels, "owner/second": .unsupported])
  }

  // MARK: - The endpoint

  /// The row of the standard slot gives the levels, the default level, the
  /// Off flag and the session levels of the recorded model.
  @Test func theStandardSlotGivesTheLevelsOfItsModel() async throws {
    let graph = try Self.makeGraph(label: "slot")

    let reply = try await ModelsGraphTests.run(graph, "{ models { slot \(Self.effortFields) } }")
    let rows = try #require(reply.data?["models"] as? [[String: Any]], "\(reply.text)")
    let effort = try Self.effort(of: try #require(rows.first))

    #expect(effort["levels"] as? [String] == Self.threeLevels.levels)
    #expect(effort["defaultLevel"] as? String == Self.threeLevels.defaultLevel)
    #expect(effort["hasOff"] as? Bool == true)
    #expect(effort["sessionLevels"] as? [String] == Self.threeLevels.sessionLevelNames)
  }

  /// A model that no load probed gives null.
  @Test func aModelThatNoLoadProbedGivesNull() async throws {
    let graph = try Self.makeGraph(label: "slot-unknown")

    let reply = try await ModelsGraphTests.run(graph, "{ models { slot \(Self.effortFields) } }")
    let rows = try #require(reply.data?["models"] as? [[String: Any]], "\(reply.text)")
    let embedding = try #require(rows.first { $0["slot"] as? String == "EMBEDDING" })

    #expect(embedding["reasoningEffort"] is NSNull, "\(embedding)")
  }

  /// A profile gives the levels and the default level of its standard
  /// model, also when the agent does not run on it.
  @Test func aProfileGivesTheLevelsOfItsStandardModel() async throws {
    let graph = try Self.makeGraph(label: "profile")

    let rows = try await ModelsGraphTests.profiles(graph, selecting: "name \(Self.effortFields)")
    let profile = try ModelsGraphTests.profile(BundledProfiles.defaultName, in: rows)
    let effort = try Self.effort(of: profile)

    #expect(effort["levels"] as? [String] == Self.threeLevels.levels)
    #expect(effort["defaultLevel"] as? String == Self.threeLevels.defaultLevel)
  }
}
