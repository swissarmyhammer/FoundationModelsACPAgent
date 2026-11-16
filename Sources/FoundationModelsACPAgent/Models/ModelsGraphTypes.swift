import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import GraphQL

// The GraphQL types of the `models` endpoint (ModelsGraph).

/// The `ModelSlot` enum of the schema.
enum ModelsGraphSlot: String, Codable, CaseIterable, Sendable {
  /// `profile.standard`.
  case standard = "STANDARD"

  /// `profile.flash`.
  case flash = "FLASH"

  /// `profile.embedding`.
  case embedding = "EMBEDDING"

  /// `profile.decision`.
  case decision = "DECISION"

  /// The schema value of a slot.
  ///
  /// - Parameter slot: The slot.
  init(_ slot: ModelSlot) {
    switch slot {
    case .standard: self = .standard
    case .flash: self = .flash
    case .embedding: self = .embedding
    case .decision: self = .decision
    }
  }

  /// The slot of this schema value.
  var slot: ModelSlot {
    switch self {
    case .standard: .standard
    case .flash: .flash
    case .embedding: .embedding
    case .decision: .decision
    }
  }
}

/// The `ModelDiskState` enum of the schema.
enum ModelsGraphDiskState: String, Codable, CaseIterable, Sendable {
  /// Each file is on disk.
  case complete = "COMPLETE"

  /// Some bytes are on disk.
  case partial = "PARTIAL"

  /// No byte is on disk.
  case missing = "MISSING"

  /// The schema value of a state.
  ///
  /// - Parameter state: The state.
  init(_ state: ModelDiskState) {
    switch state {
    case .complete: self = .complete
    case .partial: self = .partial
    case .missing: self = .missing
    }
  }
}

/// The `ModelChangeReason` enum of the schema.
enum ModelsGraphChangeReason: String, Codable, CaseIterable, Sendable {
  /// The value of a slot in the settings changed.
  case slot = "SLOT"

  /// The files of a model on disk changed, for example a download ended.
  case disk = "DISK"
}

/// The `ModelChangeApplies` enum of the schema: when a change takes effect.
enum ModelsGraphChangeApplies: String, Codable, CaseIterable, Sendable {
  /// At the next launch of the agent: the agent resolves its profile one
  /// time, when it starts. Each session of the running agent keeps the
  /// models of that launch.
  case nextLaunch = "NEXT_LAUNCH"

  /// Now: the change is a fact of the disk.
  case now = "NOW"
}

/// The fields of one model and its drafter that a row and a choice share.
struct ModelsGraphModelFields: Sendable {
  /// The repository, or the location of a local model.
  let repo: String

  /// The path inside the repository, or null.
  let path: String?

  /// The pinned revision, or null.
  let revision: String?

  /// The GGUF file of the model, or null for a model that is not GGUF.
  let file: String?

  /// The MTP drafter in the text form of a reference, or null.
  let drafter: String?

  /// The download size of the model and its drafter in bytes, or null.
  let sizeBytes: Double?

  /// The bytes of the model and its drafter on disk.
  let presentBytes: Double

  /// The disk state of the model and its drafter.
  let state: ModelsGraphDiskState

  /// The reference in the encoding of a slot key of `config.yaml`.
  let configValue: Map

  /// The error of a storage read, or null.
  let storageError: String?

  /// The fields of a report.
  ///
  /// - Parameter report: The storage report of the model.
  init(_ report: ModelsReport) {
    repo = report.ref.repo
    path = report.ref.path
    revision = report.ref.revision
    file = report.file
    drafter = report.ref.drafter?.stringValue
    sizeBytes = report.sizeBytes.map(Double.init)
    presentBytes = Double(report.presentBytes)
    state = ModelsGraphDiskState(report.state)
    configValue = report.ref.graphQLMap
    storageError = report.storageError
  }
}

/// The `SlotModel` object: the selected model of one slot.
struct ModelsGraphSlotModel: Sendable {
  /// The slot.
  let slot: ModelsGraphSlot

  /// The fields of the first candidate of the slot.
  let model: ModelsGraphModelFields

  /// Each candidate of the slot in the settings, in order.
  let candidates: [Map]

  /// The model that runs in the slot now, or null when no agent runs.
  let active: String?

  /// True when the settings differ from the launch of the running agent.
  let restartRequired: Bool

  var repo: String { model.repo }
  var path: String? { model.path }
  var revision: String? { model.revision }
  var file: String? { model.file }
  var drafter: String? { model.drafter }
  var sizeBytes: Double? { model.sizeBytes }
  var presentBytes: Double { model.presentBytes }
  var state: ModelsGraphDiskState { model.state }
  var configValue: Map { model.configValue }
  var storageError: String? { model.storageError }
}

/// The `ModelChoice` object: one model that a slot can take.
struct ModelsGraphChoice: Sendable {
  /// The fields of the model.
  let model: ModelsGraphModelFields

  var repo: String { model.repo }
  var path: String? { model.path }
  var revision: String? { model.revision }
  var file: String? { model.file }
  var drafter: String? { model.drafter }
  var sizeBytes: Double? { model.sizeBytes }
  var presentBytes: Double { model.presentBytes }
  var state: ModelsGraphDiskState { model.state }
  var configValue: Map { model.configValue }
  var storageError: String? { model.storageError }
}

/// The arguments of `Query.choices`.
struct ModelsGraphChoicesArguments: Codable, Sendable {
  /// The slot.
  let slot: ModelsGraphSlot
}

/// The arguments of `Subscription.changes`.
struct ModelsGraphChangesArguments: Codable, Sendable {
  /// The cursor to resume after, or null for the changes from now.
  let after: String?
}

extension ModelRef {
  /// This reference in its `config.yaml` encoding, as a GraphQL `JSON`
  /// value: a string, or a mapping when the reference has a drafter.
  var graphQLMap: Map {
    guard let data = try? JSONEncoder().encode(self),
      let map = try? JSONDecoder().decode(Map.self, from: data)
    else {
      return .string(stringValue)
    }
    return map
  }
}
