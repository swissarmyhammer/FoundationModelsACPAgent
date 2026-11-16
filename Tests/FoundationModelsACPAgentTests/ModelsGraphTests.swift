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
  final class FakeStorage: ModelStorageReading, Sendable {
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

  /// The builtin standard model and its drafter.
  static let standard = ProfileConfiguration.defaultStandard[0]
  static let standardDrafter = standard.drafter!

  /// The builtin flash model.
  static let flash = ProfileConfiguration.defaultFlash[0]

  /// A storage with answers for each builtin model and drafter: the
  /// standard model complete, its drafter missing, the flash model complete.
  static func builtinStorage() -> FakeStorage {
    let storage = FakeStorage()
    storage.set(info(standard, total: 1_000, present: 1_000, state: .complete))
    storage.set(info(standardDrafter, total: 200, present: 0, state: .missing))
    storage.set(info(flash, total: 300, present: 300, state: .complete))
    for ref in ProfileConfiguration.defaultEmbedding + ProfileConfiguration.defaultDecision {
      storage.set(info(ref, total: 50, present: 0, state: .missing))
    }
    return storage
  }

  /// An endpoint over the store of a settings fixture.
  static func graph(
    _ fixture: SettingsGraphFixture, storage: FakeStorage = builtinStorage(),
    launched: ProfileConfiguration? = nil, active: [ModelSlot: ModelRef] = [:],
    poll: Duration = .seconds(30)
  ) -> ModelsGraph {
    ModelsGraph(
      store: fixture.store, storage: storage, launched: launched, active: active,
      diskPollInterval: poll)
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
      "{ models { slot repo drafter file sizeBytes presentBytes state configValue candidates active "
        + "restartRequired storageError } }")
    #expect(reply.codes.isEmpty, "\(reply.text)")
    return try #require(reply.data?["models"] as? [[String: Any]])
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

  /// One row for each slot, in the profile order, with the first candidate
  /// of each slot.
  @Test func eachSlotHasOneRow() async throws {
    let fixture = try SettingsGraphFixture(label: "models-rows")

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows.map { $0["slot"] as? String } == ["STANDARD", "FLASH", "EMBEDDING", "DECISION"])
    #expect(rows[0]["repo"] as? String == Self.standard.repo)
    #expect(rows[0]["drafter"] as? String == Self.standardDrafter.stringValue)
    #expect(rows[1]["repo"] as? String == Self.flash.repo)
    #expect(rows[1]["drafter"] is NSNull)
  }

  /// The size adds the model and its drafter; the state of a complete
  /// model with a missing drafter is partial.
  @Test func theSizeAndTheStateCoverTheDrafter() async throws {
    let fixture = try SettingsGraphFixture(label: "models-drafter")

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows[0]["sizeBytes"] as? Double == 1_200)
    #expect(rows[0]["presentBytes"] as? Double == 1_000)
    #expect(rows[0]["state"] as? String == "PARTIAL")
    #expect(rows[1]["sizeBytes"] as? Double == 300)
    #expect(rows[1]["state"] as? String == "COMPLETE")
  }

  /// A model whose read fails has no size, the state MISSING, and the
  /// error text.
  @Test func aFailedReadGivesNoSizeAndTheError() async throws {
    let fixture = try SettingsGraphFixture(label: "models-error")
    let storage = Self.builtinStorage()
    let unknown = ModelRef("org/unknown-model")
    try await fixture.store.set(.array([.string(unknown.stringValue)]), at: ["profile", "flash"], level: .user)

    let rows = try await Self.rows(Self.graph(fixture, storage: storage))

    #expect(rows[1]["repo"] as? String == "org/unknown-model")
    #expect(rows[1]["sizeBytes"] is NSNull)
    #expect(rows[1]["state"] as? String == "MISSING")
    #expect((rows[1]["storageError"] as? String)?.contains("org/unknown-model") == true)
  }

  /// The GGUF file of a model is its model file, not the projector.
  @Test func theFileIsTheGGUFModelFile() async throws {
    let fixture = try SettingsGraphFixture(label: "models-gguf")
    let storage = Self.builtinStorage()
    let gguf = ModelRef("unsloth/Qwen3-8B-GGUF/Q4_K_M")
    storage.set(
      Self.info(
        gguf, total: 10, present: 10, state: .complete,
        files: ["Q4_K_M/mmproj-F16.gguf", "Q4_K_M/Qwen3-8B-Q4_K_M.gguf"]))
    try await fixture.store.set(.array([.string(gguf.stringValue)]), at: ["profile", "flash"], level: .user)

    let rows = try await Self.rows(Self.graph(fixture, storage: storage))

    #expect(rows[1]["file"] as? String == "Q4_K_M/Qwen3-8B-Q4_K_M.gguf")
  }

  /// `configValue` is the encoding of a slot key: a string for a model with
  /// no drafter, an object for a model with a drafter. It decodes to the
  /// same reference.
  @Test func theConfigValueIsTheSlotKeyEncoding() async throws {
    let fixture = try SettingsGraphFixture(label: "models-config")

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows[1]["configValue"] as? String == Self.flash.stringValue)
    let standardValue = try #require(rows[0]["configValue"] as? [String: Any])
    let data = try JSONSerialization.data(withJSONObject: standardValue)
    #expect(try JSONDecoder().decode(ModelRef.self, from: data) == Self.standard)
  }

  /// With a running agent, `active` names the model of the slot, and a
  /// slot whose settings differ from the launch needs a restart.
  @Test func aSlotChangeNeedsARestart() async throws {
    let fixture = try SettingsGraphFixture(label: "models-restart")
    let graph = Self.graph(
      fixture, launched: ProfileConfiguration(), active: [.standard: Self.standard, .flash: Self.flash])
    let other = ModelRef("org/other-flash")
    try await fixture.store.set(.array([.string(other.stringValue)]), at: ["profile", "flash"], level: .user)

    let rows = try await Self.rows(graph)

    #expect(rows[0]["restartRequired"] as? Bool == false)
    #expect(rows[1]["restartRequired"] as? Bool == true)
    #expect(rows[1]["repo"] as? String == "org/other-flash")
    #expect(rows[1]["active"] as? String == Self.flash.stringValue)
  }

  /// With no agent, no slot needs a restart and no model is active.
  @Test func withNoAgentNothingIsActive() async throws {
    let fixture = try SettingsGraphFixture(label: "models-no-agent")

    let rows = try await Self.rows(Self.graph(fixture))

    #expect(rows.allSatisfy { $0["restartRequired"] as? Bool == false })
    #expect(rows.allSatisfy { $0["active"] is NSNull })
  }

  // MARK: - choices

  /// The choices of a slot are its candidates in the settings, then the
  /// builtin candidates, with no copy.
  @Test func theChoicesAreTheCandidatesThenTheBuiltins() async throws {
    let fixture = try SettingsGraphFixture(label: "models-choices")
    let other = ModelRef("org/other-flash")
    try await fixture.store.set(
      .array([.string(other.stringValue), .string(Self.flash.stringValue)]), at: ["profile", "flash"],
      level: .user)

    let reply = try await Self.run(
      Self.graph(fixture), "{ choices(slot: FLASH) { repo state configValue } }")

    #expect(reply.codes.isEmpty, "\(reply.text)")
    let choices = try #require(reply.data?["choices"] as? [[String: Any]])
    #expect(choices.map { $0["repo"] as? String } == ["org/other-flash", Self.flash.repo])
    #expect(choices[1]["state"] as? String == "COMPLETE")
  }

  // MARK: - changes

  /// A slot change at the user level gives a SLOT change that applies at
  /// the next launch.
  @Test func aSlotChangeGivesASlotChange() async throws {
    let fixture = try SettingsGraphFixture(label: "models-slot-change")
    let graph = Self.graph(fixture)
    var events = try await graph.subscribe(
      query: Self.changesDocument, variables: [:], operationName: nil, viewer: nil
    ).makeAsyncIterator()

    try await fixture.store.set(.array([.string("org/other-flash")]), at: ["profile", "flash"], level: .user)

    let change = try await Self.next(&events)
    #expect(change["changed"] as? [String] == ["flash"])
    #expect(change["reason"] as? String == "SLOT")
    #expect(change["appliesAt"] as? String == "NEXT_LAUNCH")
  }

  /// A change of a key out of the profile gives no change.
  @Test func aChangeOutOfTheProfileGivesNoChange() {
    #expect(ModelsGraphChangeFeed.slots(changedBy: ["theme"]).isEmpty)
    #expect(ModelsGraphChangeFeed.slots(changedBy: ["profile", "decision"]) == [.decision])
    #expect(ModelsGraphChangeFeed.slots(changedBy: ["profile"]) == ModelSlot.allCases)
    #expect(ModelsGraphChangeFeed.slots(changedBy: nil) == ModelSlot.allCases)
  }

  /// A model that comes on disk while a subscriber is open gives a DISK
  /// change that applies now.
  @Test func aModelOnDiskGivesADiskChange() async throws {
    let fixture = try SettingsGraphFixture(label: "models-disk-change")
    let storage = Self.builtinStorage()
    let graph = Self.graph(fixture, storage: storage, poll: .milliseconds(20))
    var events = try await graph.subscribe(
      query: Self.changesDocument, variables: [:], operationName: nil, viewer: nil
    ).makeAsyncIterator()

    storage.set(Self.info(Self.standardDrafter, total: 200, present: 200, state: .complete))

    let change = try await Self.next(&events)
    #expect(change["changed"] as? [String] == ["standard"])
    #expect(change["reason"] as? String == "DISK")
    #expect(change["appliesAt"] as? String == "NOW")
  }

  // MARK: - The agent

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
