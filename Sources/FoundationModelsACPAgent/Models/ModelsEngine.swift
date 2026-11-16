import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The `models` endpoint reads the four slots of Router's `ModelSlot`: the
/// keys `profile.standard`, `profile.flash`, `profile.embedding` and
/// `profile.decision` of `config.yaml`.
extension ModelSlot: @retroactive CaseIterable {
  /// The four slots, in the order of the profile section.
  public static let allCases: [ModelSlot] = [.standard, .flash, .embedding, .decision]

  /// The key path of the slot in the settings.
  var keyPath: [String] {
    [AgentConfiguration.CodingKeys.profile.stringValue, rawValue]
  }

  /// The builtin candidates of the slot.
  var builtinCandidates: [ModelRef] {
    candidates(in: ProfileConfiguration())
  }

  /// The candidates of the slot in a profile section.
  ///
  /// - Parameter profile: The profile section.
  /// - Returns: The candidates, in order.
  func candidates(in profile: ProfileConfiguration) -> [ModelRef] {
    switch self {
    case .standard: profile.standard
    case .flash: profile.flash
    case .embedding: profile.embedding
    case .decision: profile.decision
    }
  }
}

/// The storage of one model and its MTP drafter, as one row of the
/// `models` endpoint shows it: Router's `ModelStorageSummary`, or the error
/// of the read.
struct ModelsReport: Sendable {
  /// The model.
  let ref: ModelRef

  /// The storage of the model and its drafter, or `nil` when a read failed.
  /// A failed read counts as a model with no byte on disk and no known size.
  let summary: ModelStorageSummary?

  /// The text of the error of the storage read, or `nil` when the read
  /// worked.
  let storageError: String?

  /// The GGUF file of the model, or `nil` for a model that is not GGUF.
  var file: String? { summary?.ggufFile }

  /// The download size of the model and its drafter, in bytes, or `nil`
  /// when the size of one of them is not known.
  var sizeBytes: Int64? { summary?.totalBytes }

  /// The bytes of the model and its drafter that are on disk.
  var presentBytes: Int64 { summary?.presentBytes ?? 0 }

  /// The disk state of the model and its drafter, with Router's rule: missing
  /// only when the model and the drafter are both missing.
  var state: ModelDiskState { summary?.state ?? .missing }
}

/// The reads of the `models` endpoint: the slot values of the settings at
/// the user level, the profile that the agent launched with, the model that
/// runs in each slot, and the storage of each model.
///
/// No read downloads a model or loads a model. Thus a host can make the
/// endpoint before the first download.
struct ModelsEngine: Sendable {
  /// The settings store. The engine reads the user level over the builtin
  /// layers, as the Settings scene of the app does.
  let store: SettingsStore

  /// The reader of the model storage.
  let storage: any ModelStorageSource

  /// The profile section that the running agent resolved at its launch, or
  /// `nil` when no agent runs yet.
  let launched: ProfileConfiguration?

  /// The model that runs in each slot, or none when no agent runs yet.
  let active: [ModelSlot: ModelRef]

  /// The candidates of a slot in the settings now, at the user level.
  ///
  /// - Parameter slot: The slot.
  /// - Returns: The candidates, in order. The builtin candidates when no
  ///   layer has a value that decodes.
  /// - Throws: What the store throws for a level file.
  func candidates(of slot: ModelSlot) async throws -> [ModelRef] {
    guard let setting = try await store.value(at: slot.keyPath, cwd: nil),
      let refs: [ModelRef] = try? setting.value.decoded(), !refs.isEmpty
    else {
      return slot.builtinCandidates
    }
    return refs
  }

  /// Tells if the candidates of a slot in the settings differ from the
  /// candidates that the running agent launched with. A change of a slot
  /// applies at the next launch of the agent.
  ///
  /// - Parameters:
  ///   - slot: The slot.
  ///   - candidates: The candidates in the settings now.
  /// - Returns: `true` when an agent runs and its candidates differ.
  func restartRequired(for slot: ModelSlot, candidates: [ModelRef]) -> Bool {
    guard let launched else {
      return false
    }
    return slot.candidates(in: launched) != candidates
  }

  /// The choices of a slot: Router's `ProfileDefinition.choices(for:)`
  /// over the candidates in the settings. The candidates come first, then
  /// the builtin choices of Router (`ModelChoices.builtin(for:)`), with no
  /// copy.
  ///
  /// - Parameter slot: The slot.
  /// - Returns: The choices, in order.
  /// - Throws: What ``candidates(of:)`` throws.
  func choices(of slot: ModelSlot) async throws -> [ModelRef] {
    let candidates = try await candidates(of: slot)
    let definition = ProfileDefinition(
      name: "models", description: "",
      standard: slot == .standard ? candidates : [],
      flash: slot == .flash ? candidates : [],
      embedding: slot == .embedding ? candidates : [],
      decision: slot == .decision ? candidates : [])
    return definition.choices(for: slot)
  }

  /// The storage of a model and its MTP drafter, from Router's
  /// `storageSummary(of:)`.
  ///
  /// - Parameter ref: The model.
  /// - Returns: The report.
  func report(of ref: ModelRef) async -> ModelsReport {
    do {
      return ModelsReport(
        ref: ref, summary: try await storage.storageSummary(of: ref), storageError: nil)
    } catch {
      return ModelsReport(ref: ref, summary: nil, storageError: String(describing: error))
    }
  }

  /// A short text of the disk state of the models of each slot. The change
  /// feed compares two of them to find a model that came on disk.
  ///
  /// - Returns: The text of each slot.
  func diskFingerprint() async -> [ModelSlot: String] {
    var texts: [ModelSlot: String] = [:]
    for slot in ModelSlot.allCases {
      guard let candidates = try? await candidates(of: slot) else {
        continue
      }
      var text = ""
      for ref in candidates {
        let report = await report(of: ref)
        text += "\(ref.stringValue)=\(report.state):\(report.presentBytes);"
      }
      texts[slot] = text
    }
    return texts
  }
}
