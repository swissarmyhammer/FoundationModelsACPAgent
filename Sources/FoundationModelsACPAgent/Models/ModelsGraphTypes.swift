import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import GraphQL

// The GraphQL types of the `models` endpoint (ModelsGraph).

/// The `ModelSlot` enum of the schema.
enum ModelsGraphSlot: String, Codable, CaseIterable, Sendable {
  /// The slot of the main work.
  case standard = "STANDARD"

  /// The slot of the fast model.
  case flash = "FLASH"

  /// The slot of the embedding model.
  case embedding = "EMBEDDING"

  /// The slot of the decision model.
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

/// The `ProfileFit` enum of the schema.
enum ModelsGraphProfileFit: String, Codable, CaseIterable, Sendable {
  /// The profile fits the memory budget of the machine.
  case fits = "FITS"

  /// The profile does not fit the memory budget of the machine.
  case doesNotFit = "DOES_NOT_FIT"

  /// The fit is not known: the endpoint has no fit estimate.
  case unknown = "UNKNOWN"

  /// The schema value of a report.
  ///
  /// - Parameter report: The report, or `nil` when the endpoint has no fit
  ///   estimate.
  init(_ report: ProfileFitReport?) {
    guard let report else {
      self = .unknown
      return
    }
    self = report.fits ? .fits : .doesNotFit
  }
}

/// The `ModelChangeReason` enum of the schema.
enum ModelsGraphChangeReason: String, Codable, CaseIterable, Sendable {
  /// The value of `profile` in the settings changed.
  case profile = "PROFILE"

  /// The files of a model on disk changed, for example a download ended.
  case disk = "DISK"
}

/// The `ProfileLayer` enum of the schema: the layer of a profile file.
enum ModelsGraphProfileLayer: String, Codable, CaseIterable, Sendable {
  /// The project layer of a working directory.
  case project = "PROJECT"

  /// The user layer.
  case user = "USER"

  /// The bundled profiles, which are read-only.
  case bundled = "BUNDLED"

  /// The schema value of a layer.
  ///
  /// - Parameter layer: The layer.
  init(_ layer: ProfileLayer) {
    switch layer {
    case .project: self = .project
    case .user: self = .user
    case .bundled: self = .bundled
    }
  }

  /// The settings level of a change of this layer.
  ///
  /// - Parameter cwd: The working directory of the project layer, or `nil`.
  /// - Returns: The level.
  /// - Throws: ``ModelsGraphError/readOnlyLayer`` for the bundled layer, and
  ///   ``ModelsGraphError/missingWorkingDirectory`` for the project layer
  ///   with no working directory.
  func level(cwd: URL?) throws -> SettingsLevel {
    switch self {
    case .user:
      return .user
    case .bundled:
      throw ModelsGraphError.readOnlyLayer
    case .project:
      guard let cwd else { throw ModelsGraphError.missingWorkingDirectory }
      return .session(cwd)
    }
  }
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
    storageError = report.storageError
  }
}

/// The `ReasoningEffort` object: the reasoning effort levels of one model
/// (D218), which the probe of its chat template found at its first load on
/// this machine (``ReasoningEffortLevelsRecord``).
struct ModelsGraphReasoningEffort: Sendable {
  /// The levels of the model, in the order of the probe, with the names of
  /// the model. Empty for a model with no levels.
  let levels: [String]

  /// The level that the model uses with no `reasoning_effort`, or `nil`
  /// for a model with no levels.
  let defaultLevel: String?

  /// True when the model can turn its reasoning off.
  let hasOff: Bool

  /// The values that a session on the model and the
  /// `profiles.<name>.effort` setting take: each level, then "Off" when the
  /// model has an Off level. Empty for a model with no levels.
  let sessionLevels: [String]

  /// The object of the levels of a model.
  ///
  /// - Parameter levels: The levels of the model.
  init(_ levels: ReasoningEffortLevels) {
    self.levels = levels.levels
    defaultLevel = levels.defaultLevel
    hasOff = levels.hasOff
    sessionLevels = levels.sessionLevelNames
  }

  /// The object of the levels of a model in a record of the levels.
  ///
  /// - Parameters:
  ///   - ref: The model.
  ///   - recorded: The levels of each recorded model, by the text form of
  ///     its reference.
  /// - Returns: The object, or `nil` when no load on this machine probed
  ///   the model.
  static func of(_ ref: ModelRef, in recorded: [String: ReasoningEffortLevels]) -> Self? {
    recorded[ref.stringValue].map(Self.init)
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

  /// The reasoning effort levels of the first candidate, or `nil` when no
  /// load on this machine probed it.
  let reasoningEffort: ModelsGraphReasoningEffort?

  var repo: String { model.repo }
  var path: String? { model.path }
  var revision: String? { model.revision }
  var file: String? { model.file }
  var drafter: String? { model.drafter }
  var sizeBytes: Double? { model.sizeBytes }
  var presentBytes: Double { model.presentBytes }
  var state: ModelsGraphDiskState { model.state }
  var storageError: String? { model.storageError }
}

/// The `ProfileModel` object: the model of one slot of a profile.
struct ModelsGraphProfileModel: Sendable {
  /// The slot.
  let slot: ModelsGraphSlot

  /// The fields of the first candidate of the slot in the profile.
  let model: ModelsGraphModelFields

  /// The reasoning effort levels of the first candidate, or `nil` when no
  /// load on this machine probed it.
  let reasoningEffort: ModelsGraphReasoningEffort?

  var repo: String { model.repo }
  var path: String? { model.path }
  var revision: String? { model.revision }
  var file: String? { model.file }
  var drafter: String? { model.drafter }
  var sizeBytes: Double? { model.sizeBytes }
  var presentBytes: Double { model.presentBytes }
  var state: ModelsGraphDiskState { model.state }
  var storageError: String? { model.storageError }
}

/// The `ModelProfile` object: one profile that the user can select.
struct ModelsGraphProfile: Sendable {
  /// The name of the profile: the value of `profile`.
  let name: String

  /// The layer of the file of the profile.
  let layer: ModelsGraphProfileLayer

  /// The description of the profile.
  let description: String

  /// True when `profile` at the user level names this profile.
  let selected: Bool

  /// True when the running agent launched with this profile.
  let active: Bool

  /// True when this profile is selected and the running agent launched
  /// with a different profile.
  let restartRequired: Bool

  /// The model of each slot.
  let models: [ModelsGraphProfileModel]

  /// The download size of the different models and drafters of the
  /// profile, each counted one time, or `nil` when a size is not known.
  let downloadBytes: Double?

  /// The bytes of the different models and drafters on disk.
  let presentBytes: Double

  /// The disk state of the profile.
  let state: ModelsGraphDiskState

  /// The fit of the profile against the memory budget of the machine.
  let fit: ModelsGraphProfileFit

  /// The bytes that the profile needs, or `nil`.
  let requiredBytes: Double?

  /// The memory budget of the machine, or `nil` when no estimate ran.
  let budgetBytes: Double?

  /// The readable reason of a fit that failed, or `nil`.
  let fitError: String?

  /// The context window of the fit, in tokens, or `nil` when the profile
  /// does not fit or no estimate ran.
  let contextTokens: Int?

  /// The memory of the Mac that a bundled profile is for, such as
  /// "32 GB", or `nil` for a profile file of the user or the project.
  let targetMemory: String?

  /// The reasoning effort levels of the `standard` model of the profile,
  /// which the `profiles.<name>.effort` setting takes, or `nil` when no
  /// load on this machine probed that model.
  let reasoningEffort: ModelsGraphReasoningEffort?
}

/// The arguments of `Query.profiles`.
struct ModelsGraphProfilesArguments: Codable, Sendable {
  /// The absolute path of the working directory whose project layer the
  /// list reads, or `nil` for the user layer and the bundled profiles.
  let cwd: String?
}

/// The arguments of `Mutation.saveProfile`.
struct ModelsGraphSaveProfileArguments: Codable, Sendable {
  /// The name of the profile: the name of its file.
  let name: String

  /// The keys of the profile file. Each key is optional.
  let profile: Map

  /// The layer of the file.
  let layer: ModelsGraphProfileLayer

  /// The working directory of the project layer, or `nil`.
  let cwd: String?
}

/// The arguments of `Mutation.deleteProfile`.
struct ModelsGraphDeleteProfileArguments: Codable, Sendable {
  /// The name of the profile.
  let name: String

  /// The layer of the file.
  let layer: ModelsGraphProfileLayer

  /// The working directory of the project layer, or `nil`.
  let cwd: String?
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
