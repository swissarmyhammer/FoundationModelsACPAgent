import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// What the `models` endpoint needs from the model storage: the download
/// size and the disk state of one model, with no download and no model load.
///
/// `ModelStorage` of FoundationModelsExtras conforms. A test gives a reader
/// that makes no network request.
public protocol ModelStorageReading: Sendable {
  /// The download size and the disk state of one model.
  ///
  /// - Parameter ref: The model.
  /// - Returns: The information of the model.
  /// - Throws: The error of the read.
  func storageInfo(of ref: ModelRef) async throws -> ModelStorageInfo
}

extension ModelStorage: ModelStorageReading {}

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

/// The disk state of a model together with its MTP drafter.
enum ModelsDiskState: Sendable, Equatable {
  /// Each file of the model and of its drafter is on disk.
  case complete

  /// Some bytes are on disk, but not all of them.
  case partial

  /// No byte is on disk.
  case missing
}

/// The storage of one model and its MTP drafter, as one row of the
/// `models` endpoint shows it.
struct ModelsReport: Sendable, Equatable {
  /// The model.
  let ref: ModelRef

  /// The GGUF file of the model, or `nil` for a model that is not GGUF.
  let file: String?

  /// The download size of the model and its drafter, in bytes, or `nil`
  /// when the size of one of them is not known.
  let sizeBytes: Int64?

  /// The bytes of the model and its drafter that are on disk.
  let presentBytes: Int64

  /// The disk state of the model and its drafter.
  let state: ModelsDiskState

  /// The text of each error of a storage read, or `nil` when each read
  /// worked. A failed read counts as a model with no byte on disk and no
  /// known size.
  let storageError: String?
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
  let storage: any ModelStorageReading

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

  /// The choices of a slot: the candidates in the settings, then the
  /// builtin candidates of the slot, with no copy.
  ///
  /// - Parameter slot: The slot.
  /// - Returns: The choices, in order.
  /// - Throws: What ``candidates(of:)`` throws.
  func choices(of slot: ModelSlot) async throws -> [ModelRef] {
    var seen = Set<String>()
    return (try await candidates(of: slot) + slot.builtinCandidates).filter {
      seen.insert($0.stringValue).inserted
    }
  }

  /// The storage of a model and its MTP drafter.
  ///
  /// - Parameter ref: The model.
  /// - Returns: The report.
  func report(of ref: ModelRef) async -> ModelsReport {
    async let model = read(ref)
    let drafter = await ref.drafter.asyncMap(read)
    let parts = [await model] + (drafter.map { [$0] } ?? [])
    let infos = parts.compactMap { try? $0.get() }
    let errors = parts.compactMap { part -> String? in
      guard case .failure(let error) = part else {
        return nil
      }
      return String(describing: error)
    }
    let totals = parts.map { (try? $0.get())?.totalBytes }
    let present = infos.reduce(Int64(0)) { $0 + $1.presentBytes }
    return ModelsReport(
      ref: ref,
      file: (try? (await model).get()).flatMap(Self.ggufFile),
      sizeBytes: totals.contains(nil) ? nil : totals.compactMap { $0 }.reduce(0, +),
      presentBytes: present,
      state: Self.state(of: parts),
      storageError: errors.isEmpty ? nil : errors.joined(separator: "; "))
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

  // MARK: - Helpers

  /// One storage read, as a result.
  ///
  /// - Parameter ref: The model.
  /// - Returns: The information, or the error of the read.
  private func read(_ ref: ModelRef) async -> Result<ModelStorageInfo, any Error> {
    do {
      return .success(try await storage.storageInfo(of: ref))
    } catch {
      return .failure(error)
    }
  }

  /// The disk state of a model and its drafter: complete when each read
  /// says complete, missing when no byte is on disk and no read says
  /// complete, else partial.
  ///
  /// - Parameter parts: The read of the model and of its drafter.
  /// - Returns: The state.
  private static func state(of parts: [Result<ModelStorageInfo, any Error>]) -> ModelsDiskState {
    let infos = parts.compactMap { try? $0.get() }
    if infos.count == parts.count, infos.allSatisfy({ $0.state == .complete }) {
      return .complete
    }
    let present = infos.reduce(Int64(0)) { $0 + $1.presentBytes }
    if present == 0, !infos.contains(where: { $0.state == .complete }) {
      return .missing
    }
    return .partial
  }

  /// The GGUF model file of a storage read: the first `.gguf` file that is
  /// not a projector.
  ///
  /// - Parameter info: The storage read.
  /// - Returns: The file, or `nil` for a model that is not GGUF.
  private static func ggufFile(of info: ModelStorageInfo) -> String? {
    info.files.first { file in
      file.lowercased().hasSuffix(".gguf") && !file.lowercased().contains("mmproj")
    }
  }
}

extension Optional {
  /// Maps the wrapped value with an async function.
  ///
  /// - Parameter transform: The function.
  /// - Returns: The mapped value, or `nil`.
  fileprivate func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
    switch self {
    case .some(let value): await transform(value)
    case .none: nil
    }
  }
}
