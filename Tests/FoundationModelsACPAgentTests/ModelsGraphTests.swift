import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsRouter
import GraphQL
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The `models` GraphQL endpoint (TestudoApp ^453zgr3, D183 (c), D100 (d)):
/// the model of each slot, the choices of a slot, their storage, and the
/// changes of the slots and of the disk.
@Suite struct ModelsGraphTests {
  // MARK: - Fixture

  /// A storage reader with fixed answers, which makes no network request.
  final class FakeStorage: ModelStorageSource, Sendable {
    /// The answer for each reference, by its text form. A reference with no
    /// answer throws ``Missing``.
    private let answers: Mutex<[String: ModelStorageInfo]>

    /// The error of a reference with no answer.
    struct Missing: Error, CustomStringConvertible {
      let ref: String
      var description: String { "no listing for \(ref)" }
    }

    init(_ answers: [String: ModelStorageInfo] = [:]) {
      self.answers = Mutex(answers)
    }

    /// Sets the answer of a reference.
    func set(_ info: ModelStorageInfo) {
      answers.withLock { $0[info.ref.stringValue] = info }
    }

    func storageInfo(of ref: ModelRef) async throws -> ModelStorageInfo {
      guard let info = answers.withLock({ $0[ref.stringValue] }) else {
        throw Missing(ref: ref.stringValue)
      }
      return info
    }
  }

  /// A storage answer.
  static func info(
    _ ref: ModelRef, total: Int64?, present: Int64, state: ModelDiskState, files: [String] = []
  ) -> ModelStorageInfo {
    ModelStorageInfo(
      ref: ref, revision: nil, files: files, totalBytes: total, presentBytes: present,
      diskBytes: present, state: state)
  }

  /// The builtin standard model and its drafter: the models of the
  /// profile `large`.
  static let standard = BundledProfiles.defaultProfile.standard[0]
  static let standardDrafter = standard.drafter!

  /// The builtin flash model: the standard model, with its drafter.
  static let flash = BundledProfiles.defaultProfile.flash[0]

  /// The model of the profile `small`, with its drafter.
  static let smallModel = BundledProfiles.named("small")!.standard[0]

  /// The drafter of the model of `small`.
  static let smallDrafter = smallModel.drafter!

  /// A storage with answers for each model and drafter of the bundled
  /// profiles: the standard model complete, its drafter missing, the model
  /// of `small` complete, its drafter missing, each other model missing.
  static func builtinStorage() -> FakeStorage {
    let storage = FakeStorage()
    for ref in ModelsEngine.builtinModels {
      storage.set(info(ref, total: 50, present: 0, state: .missing))
    }
    storage.set(info(standard, total: 1_000, present: 1_000, state: .complete))
    storage.set(info(standardDrafter, total: 200, present: 0, state: .missing))
    storage.set(info(smallModel, total: 300, present: 300, state: .complete))
    storage.set(info(smallDrafter, total: 100, present: 0, state: .missing))
    return storage
  }

  /// The context window of each answer of ``StubFit`` that fits, in
  /// tokens.
  static let stubContextTokens = 40_960

  /// A fit estimate with fixed answers, which counts its calls.
  final class StubFit: ProfileFitEstimating, Sendable {
    /// The answer of each profile, by name. A profile with no answer fits.
    let answers: [String: ProfileFitReport]

    /// The calls, by the name of the profile.
    let calls = Mutex<[String]>([])

    init(_ answers: [String: ProfileFitReport] = [:]) {
      self.answers = answers
    }

    func fitReport(of profile: ProfileDefinition) async -> ProfileFitReport {
      calls.withLock { $0.append(profile.name) }
      return answers[profile.name]
        ?? ProfileFitReport(
          fits: true, requiredBytes: 1, contextTokens: ModelsGraphTests.stubContextTokens,
          budgetBytes: 2)
    }
  }

  /// An endpoint over the store of a settings fixture.
  static func graph(
    _ fixture: SettingsGraphFixture, storage: FakeStorage = builtinStorage(),
    launched: ProfileConfiguration? = nil, active: [ModelSlot: ModelRef] = [:],
    fit: StubFit? = nil, poll: Duration = .seconds(30)
  ) -> ModelsGraph {
    ModelsGraph(
      store: fixture.store, storage: storage, launched: launched, active: active,
      fitEstimator: fit, diskPollInterval: poll)
  }

  /// Runs a document and parses the reply.
  static func run(_ graph: ModelsGraph, _ document: String) async throws -> GraphQLReply {
    try GraphQLReply(
      try await graph.execute(query: document, variables: [:], operationName: nil, viewer: nil))
  }

  /// The rows of `models`.
  static func rows(_ graph: ModelsGraph) async throws -> [[String: Any]] {
    let reply = try await run(
      graph,
      "{ models { slot repo drafter file sizeBytes presentBytes state candidates active "
        + "restartRequired storageError } }")
    #expect(reply.codes.isEmpty, "\(reply.text)")
    return try #require(reply.data?["models"] as? [[String: Any]])
  }

  /// The rows of `profiles`.
  static func profiles(_ graph: ModelsGraph) async throws -> [[String: Any]] {
    let reply = try await run(
      graph,
      "{ profiles { name description selected active restartRequired downloadBytes presentBytes state "
        + "fit requiredBytes budgetBytes fitError models { slot repo drafter sizeBytes state } } }")
    #expect(reply.codes.isEmpty, "\(reply.text)")
    return try #require(reply.data?["profiles"] as? [[String: Any]])
  }

  /// The row of one profile of `profiles`.
  static func profile(_ name: String, in rows: [[String: Any]]) throws -> [String: Any] {
    try #require(rows.first { $0["name"] as? String == name })
  }

  /// Selects a profile at the user level.
  static func select(_ name: String, in fixture: SettingsGraphFixture) async throws {
    try await fixture.store.set(.string(name), at: ["profile"], level: .user)
  }

  /// The next event of a subscription, as an object.
  static func next(
    _ events: inout AsyncThrowingStream<String, Error>.AsyncIterator
  ) async throws -> [String: Any] {
    let text = try #require(try await events.next())
    let reply = try GraphQLReply(text)
    return try #require(reply.data?["changes"] as? [String: Any], "\(text)")
  }

  /// The subscription document.
  static let changesDocument = "subscription { changes { changed reason appliesAt } }"

  // MARK: - models

  /// One row for each slot of the selected profile, in the profile order,
  /// with the first candidate of each slot. The flash row of `large` names
  /// the standard model and its drafter.
  @Test func eachSlotHasOneRow() async throws {
    let fixture = try SettingsGraphFixture(label: "models-rows")

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows.map { $0["slot"] as? String } == ["STANDARD", "FLASH", "EMBEDDING", "DECISION"])
    #expect(rows[0]["repo"] as? String == Self.standard.repo)
    #expect(rows[0]["drafter"] as? String == Self.standardDrafter.stringValue)
    #expect(rows[1]["repo"] as? String == Self.flash.repo)
    #expect(rows[1]["drafter"] as? String == Self.standardDrafter.stringValue)
  }

  /// The rows follow `profile`: the slots of `small` name its model and
  /// its drafter.
  @Test func theRowsFollowTheSelectedProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "models-selected-rows")
    try await Self.select("small", in: fixture)

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows[0]["repo"] as? String == Self.smallModel.repo)
    #expect(rows[1]["repo"] as? String == Self.smallModel.repo)
    #expect(rows[1]["drafter"] as? String == Self.smallDrafter.stringValue)
  }

  /// The size adds the model and its drafter; the state of a complete
  /// model with a missing drafter is partial.
  @Test func theSizeAndTheStateCoverTheDrafter() async throws {
    let fixture = try SettingsGraphFixture(label: "models-drafter")

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows[0]["sizeBytes"] as? Double == 1_200)
    #expect(rows[0]["presentBytes"] as? Double == 1_000)
    #expect(rows[0]["state"] as? String == "PARTIAL")
  }

  /// The state follows the rule of Router: MISSING only when the model and
  /// its drafter are both missing, else PARTIAL when one part is not
  /// complete.
  @Test func missingNeedsTheModelAndTheDrafterMissing() async throws {
    let fixture = try SettingsGraphFixture(label: "models-missing")
    let storage = Self.builtinStorage()
    storage.set(Self.info(Self.standard, total: 1_000, present: 0, state: .missing))
    storage.set(
      Self.info(
        Self.standardDrafter, total: 200, present: 0, state: .partial(presentBytes: 0, totalBytes: 200)))
    let partial = try await Self.rows(Self.graph(fixture, storage: storage))

    storage.set(Self.info(Self.standardDrafter, total: 200, present: 0, state: .missing))
    let missing = try await Self.rows(Self.graph(fixture, storage: storage))

    #expect(partial[0]["state"] as? String == "PARTIAL")
    #expect(missing[0]["state"] as? String == "MISSING")
  }

  /// A model whose read fails has no size, the state MISSING, and the
  /// error text.
  @Test func aFailedReadGivesNoSizeAndTheError() async throws {
    let fixture = try SettingsGraphFixture(label: "models-error")
    let storage = FakeStorage()
    storage.set(Self.info(Self.standard, total: 1_000, present: 1_000, state: .complete))
    storage.set(Self.info(Self.standardDrafter, total: 200, present: 200, state: .complete))

    let rows = try await Self.rows(Self.graph(fixture, storage: storage))

    let embedding = BundledProfiles.defaultProfile.embedding[0]
    #expect(rows[2]["repo"] as? String == embedding.repo)
    #expect(rows[2]["sizeBytes"] is NSNull)
    #expect(rows[2]["state"] as? String == "MISSING")
    #expect((rows[2]["storageError"] as? String)?.contains(embedding.stringValue) == true)
  }

  /// With a running agent, `active` names the model of the slot, and a
  /// slot whose model differs from the launch needs a restart.
  @Test func aProfileChangeNeedsARestartOfTheChangedSlots() async throws {
    let fixture = try SettingsGraphFixture(label: "models-restart")
    let graph = Self.graph(
      fixture, launched: ProfileConfiguration(), active: [.standard: Self.standard, .flash: Self.flash])
    try await Self.select("small", in: fixture)

    let rows = try await Self.rows(graph)

    #expect(rows[0]["restartRequired"] as? Bool == true)
    #expect(rows[1]["restartRequired"] as? Bool == true)
    #expect(rows[2]["restartRequired"] as? Bool == false)
    #expect(rows[1]["repo"] as? String == Self.smallModel.repo)
    #expect(rows[1]["active"] as? String == Self.flash.stringValue)
  }

  /// With no agent, no slot needs a restart and no model is active.
  @Test func withNoAgentNothingIsActive() async throws {
    let fixture = try SettingsGraphFixture(label: "models-no-agent")

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows.allSatisfy { $0["restartRequired"] as? Bool == false })
    #expect(rows.allSatisfy { $0["active"] is NSNull })
  }

  // MARK: - profiles

  /// One row for each bundled profile, in the order of the list, each with
  /// a model for each slot. With no agent, `large` is selected and no
  /// profile is active; with no estimate, the fit is UNKNOWN.
  @Test func eachBuiltinProfileHasOneRow() async throws {
    let fixture = try SettingsGraphFixture(label: "models-profiles")

    let rows = try await Self.profiles(Self.graph(fixture))

    #expect(rows.map { $0["name"] as? String } == BundledProfiles.all.map(\.name))
    #expect(rows.map { $0["description"] as? String } == BundledProfiles.all.map(\.description))
    #expect(rows.allSatisfy { ($0["models"] as? [[String: Any]])?.count == 4 })
    #expect(rows.map { $0["selected"] as? Bool } == rows.map { $0["name"] as? String == "large" })
    #expect(rows.allSatisfy { $0["active"] as? Bool == false && $0["restartRequired"] as? Bool == false })
    #expect(rows.allSatisfy { $0["fit"] as? String == "UNKNOWN" && $0["budgetBytes"] is NSNull })
  }

  /// A model of two slots counts one time in `downloadBytes`: `large` names
  /// one model with its drafter in `standard` and `flash`.
  @Test func aModelOfTwoSlotsCountsOneTime() async throws {
    let fixture = try SettingsGraphFixture(label: "models-shared")

    let rows = try await Self.profiles(Self.graph(fixture))

    let large = try Self.profile("large", in: rows)
    // The model 1 000 and the drafter 200 one time, the embedding and the
    // decision models 50 each.
    #expect(large["downloadBytes"] as? Double == 1_300)
    #expect(large["presentBytes"] as? Double == 1_000)
    #expect(large["state"] as? String == "PARTIAL")
    // The model 300 and its drafter 100, the embedding and the decision
    // models 50 each.
    let small = try Self.profile("small", in: rows)
    #expect(small["downloadBytes"] as? Double == 500)
    #expect(small["presentBytes"] as? Double == 300)
  }

  /// A profile whose each model is on disk is COMPLETE, and a size that is
  /// not known gives no download size.
  @Test func theStateAndTheSizeOfAProfile() async throws {
    let fixture = try SettingsGraphFixture(label: "models-profile-state")
    let storage = FakeStorage()
    for ref in ModelsEngine.builtinModels + ModelsEngine.builtinModels.compactMap(\.drafter) {
      storage.set(Self.info(ref, total: 10, present: 10, state: .complete))
    }
    storage.set(Self.info(Self.smallModel, total: nil, present: 10, state: .complete))

    let rows = try await Self.profiles(Self.graph(fixture, storage: storage))

    #expect(try Self.profile("large", in: rows)["state"] as? String == "COMPLETE")
    #expect(try Self.profile("small", in: rows)["downloadBytes"] is NSNull)
  }

  /// `selected` follows `profile` at the user level. With a running
  /// agent of an other profile, the selected profile needs a restart, and
  /// the profile of the launch is active.
  @Test func selectedFollowsThePreset() async throws {
    let fixture = try SettingsGraphFixture(label: "models-selected")
    let graph = Self.graph(fixture, launched: ProfileConfiguration())
    try await Self.select("small", in: fixture)

    let rows = try await Self.profiles(graph)

    #expect(rows.compactMap { $0["selected"] as? Bool == true ? $0["name"] as? String : nil } == ["small"])
    #expect(try Self.profile("small", in: rows)["restartRequired"] as? Bool == true)
    #expect(try Self.profile("large", in: rows)["active"] as? Bool == true)
    #expect(try Self.profile("large", in: rows)["restartRequired"] as? Bool == false)
  }

  /// The fit of each profile comes from the estimate: FITS with the bytes,
  /// or DOES_NOT_FIT with the reason. The endpoint keeps each estimate
  /// until the settings or the disk change.
  @Test func theFitComesFromTheEstimate() async throws {
    let fixture = try SettingsGraphFixture(label: "models-fit")
    let fit = StubFit([
      "large": ProfileFitReport(
        fits: false, requiredBytes: nil, budgetBytes: 32, failure: "needs 40, has 32"),
      "small": ProfileFitReport(fits: true, requiredBytes: 20, budgetBytes: 32),
    ])
    let graph = Self.graph(fixture, fit: fit)

    let rows = try await Self.profiles(graph)
    _ = try await Self.profiles(graph)

    let large = try Self.profile("large", in: rows)
    #expect(large["fit"] as? String == "DOES_NOT_FIT")
    #expect(large["requiredBytes"] is NSNull)
    #expect(large["budgetBytes"] as? Double == 32)
    #expect(large["fitError"] as? String == "needs 40, has 32")
    let small = try Self.profile("small", in: rows)
    #expect(small["fit"] as? String == "FITS")
    #expect(small["requiredBytes"] as? Double == 20)
    #expect(small["fitError"] is NSNull)
    #expect(fit.calls.withLock { $0 } == BundledProfiles.all.map(\.name))
  }

  /// The fields of `contextTokens` and `targetMemory` of each row, by the
  /// name of the profile.
  ///
  /// - Parameter graph: The endpoint.
  /// - Returns: The rows, by name.
  static func windowRows(_ graph: ModelsGraph) async throws -> [String: [String: Any]] {
    let reply = try await run(graph, "{ profiles { name contextTokens targetMemory } }")
    #expect(reply.codes.isEmpty, "\(reply.text)")
    let rows = try #require(reply.data?["profiles"] as? [[String: Any]])
    return Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in (row["name"] as? String).map { ($0, row) } })
  }

  /// The window of a profile that fits comes from the estimate.
  @Test func theWindowComesFromTheEstimate() async throws {
    let fixture = try SettingsGraphFixture(label: "models-window")
    let graph = Self.graph(fixture, fit: StubFit())

    let rows = try await Self.windowRows(graph)

    #expect(rows["small"]?["contextTokens"] as? Int == Self.stubContextTokens)
  }

  /// A profile that does not fit has no window.
  @Test func aProfileThatDoesNotFitHasNoWindow() async throws {
    let fixture = try SettingsGraphFixture(label: "models-no-window")
    let fit = StubFit([
      "large": ProfileFitReport(
        fits: false, requiredBytes: nil, budgetBytes: 32, failure: "needs 40, has 32")
    ])

    let rows = try await Self.windowRows(Self.graph(fixture, fit: fit))

    #expect(rows["large"]?["contextTokens"] is NSNull)
  }

  /// Each bundled profile has the memory of the Mac that it is for.
  @Test func eachBundledProfileHasItsTargetMemory() async throws {
    let fixture = try SettingsGraphFixture(label: "models-target-memory")

    let rows = try await Self.windowRows(Self.graph(fixture))

    #expect(
      rows.mapValues { $0["targetMemory"] as? String }
        == ["large": "48 GB or more", "medium": "32 GB", "small": "16 GB or 24 GB"])
  }

  /// With no `profile` at the user level, the selected profile is the
  /// choice of the store, as the load of a session does.
  @Test func noProfileKeySelectsTheChoiceOfTheStore() async throws {
    let fixture = try SettingsGraphFixture(
      label: "models-no-profile-key", secretStore: InMemorySecretStore(),
      fallbackProfileName: BundledProfiles.smallestName)

    let rows = try await Self.profiles(Self.graph(fixture))

    #expect(
      rows.compactMap { $0["selected"] as? Bool == true ? $0["name"] as? String : nil }
        == [BundledProfiles.smallestName])
  }

  /// A user `profile` that no layer has selects the fallback profile, as
  /// the load of a session does.
  @Test func anUnknownProfileNameSelectsTheFallback() async throws {
    let fixture = try SettingsGraphFixture(label: "models-unknown-on-disk")
    let root = try #require(
      SettingsFoldersFixture.layerRoot(
        of: .user, in: fixture.settingsFolders, workingDirectory: fixture.firstDirectory))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "profile: nosuch\n".write(
      to: root.appendingPathComponent(ConfigurationLoader.configFileName),
      atomically: true, encoding: .utf8)

    let rows = try await Self.profiles(Self.graph(fixture))

    #expect(
      rows.compactMap { $0["selected"] as? Bool == true ? $0["name"] as? String : nil }
        == [fixture.store.fallbackProfileName])
  }

  /// A name that no layer has is refused by the settings store, and the
  /// error names the profiles.
  @Test func anUnknownProfileNameIsRefused() async throws {
    let fixture = try SettingsGraphFixture(label: "models-unknown")

    let error = await #expect(throws: (any Error).self) {
      try await Self.select("huge", in: fixture)
    }

    #expect(String(describing: try #require(error)).contains("large"))
  }

  // MARK: - changes

  /// A write of `profile` at the user level gives a PROFILE change of each
  /// slot that applies at the next launch.
  @Test func aProfileWriteGivesAProfileChange() async throws {
    let fixture = try SettingsGraphFixture(label: "models-profile-change")
    let graph = Self.graph(fixture)
    var events = try await graph.subscribe(
      query: Self.changesDocument, variables: [:], operationName: nil, viewer: nil
    ).makeAsyncIterator()

    try await Self.select("small", in: fixture)

    let change = try await Self.next(&events)
    #expect(change["changed"] as? [String] == ["standard", "flash", "embedding", "decision"])
    #expect(change["reason"] as? String == "PROFILE")
    #expect(change["appliesAt"] as? String == "NEXT_LAUNCH")
  }

  /// Only a change that can change `profile` changes the profile.
  @Test func onlyAProfileChangeChangesTheProfile() {
    #expect(!ModelsGraphChangeFeed.changesProfile(["theme"]))
    #expect(ModelsGraphChangeFeed.changesProfile(["profile", "preset"]))
    #expect(ModelsGraphChangeFeed.changesProfile(["profile"]))
    #expect(ModelsGraphChangeFeed.changesProfile(nil))
  }

  /// A model that comes on disk while a subscriber is open gives a DISK
  /// change that applies now, for each slot of the selected profile that
  /// names it: the standard and flash slots of `large` name one model and
  /// one drafter.
  @Test func aModelOnDiskGivesADiskChange() async throws {
    let fixture = try SettingsGraphFixture(label: "models-disk-change")
    let storage = Self.builtinStorage()
    let graph = Self.graph(fixture, storage: storage, poll: .milliseconds(20))
    var events = try await graph.subscribe(
      query: Self.changesDocument, variables: [:], operationName: nil, viewer: nil
    ).makeAsyncIterator()

    storage.set(Self.info(Self.standardDrafter, total: 200, present: 200, state: .complete))

    let change = try await Self.next(&events)
    #expect(change["changed"] as? [String] == ["standard", "flash"])
    #expect(change["reason"] as? String == "DISK")
    #expect(change["appliesAt"] as? String == "NOW")
  }

  /// A model of an other profile that comes on disk gives a DISK change
  /// that names no slot: the state of that profile changed.
  @Test func aModelOfAnOtherProfileGivesADiskChangeWithNoSlot() async throws {
    let fixture = try SettingsGraphFixture(label: "models-disk-other")
    let storage = Self.builtinStorage()
    let graph = Self.graph(fixture, storage: storage, poll: .milliseconds(20))
    var events = try await graph.subscribe(
      query: Self.changesDocument, variables: [:], operationName: nil, viewer: nil
    ).makeAsyncIterator()

    storage.set(Self.info(Self.smallDrafter, total: 100, present: 100, state: .complete))

    let change = try await Self.next(&events)
    #expect(change["changed"] as? [String] == [])
    #expect(change["reason"] as? String == "DISK")
  }

  // MARK: - The agent

  /// The endpoint of a composed agent reads the storage that `compose`
  /// got, thus a test makes no network request.
  @Test func theComposedAgentReadsTheGivenStorage() async throws {
    let storage = FakeStorage()
    for ref in ModelsEngine.builtinModels + ModelsEngine.builtinModels.compactMap(\.drafter) {
      storage.set(Self.info(ref, total: 7, present: 7, state: .complete))
    }
    let composed = try await composeStubAgent(
      name: "ModelsGraphTests", label: "ModelsGraphTests-storage", modelStorage: storage)

    let rows = try await Self.rows(composed.agent.modelsEndpoint)
    let profiles = try await Self.profiles(composed.agent.modelsEndpoint)

    #expect(rows.allSatisfy { $0["state"] as? String == "COMPLETE" })
    #expect(rows.allSatisfy { $0["storageError"] is NSNull })
    #expect(rows.allSatisfy { $0["active"] is String })
    #expect(try Self.profile("large", in: profiles)["active"] as? Bool == true)
    // The agent gives its router as the fit estimate.
    #expect(profiles.allSatisfy { $0["fit"] as? String != "UNKNOWN" })
    #expect(profiles.allSatisfy { $0["budgetBytes"] is Double })
  }

  /// Each session of the agent has the top-level `models` tool, which gives
  /// the one `models` endpoint of the agent.
  @Test func aSessionHasTheModelsToolAndTheEndpointOfTheAgent() async throws {
    let composed = try await composeStubAgent(name: "ModelsGraphTests", label: "ModelsGraphTests-agent")
    _ = try await composed.agent.initialize(AgentClientHarness.makeInitializeRequest())
    let folder = makeResolvedDirectory(label: "ModelsGraphTests-agent-cwd")
    let id = try await composed.agent.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: folder)
    ).sessionId

    let surface = await composed.agent.sessions[id]?.surface
    await composed.closeOpenSessions()

    #expect(surface?.tools.contains { $0.name == ModelsGraph.endpointName } == true)
    let endpoint = surface?.graphQLEndpoints.first { $0.name == ModelsGraph.endpointName }
    #expect((endpoint as AnyObject?) === composed.agent.modelsEndpoint)
  }
}
