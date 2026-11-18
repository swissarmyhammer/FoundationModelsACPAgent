import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The `models` endpoint reads the four slots of Router's `ModelSlot` in the
/// profile that `profile` selects.
extension ModelSlot: @retroactive CaseIterable {
  /// The four slots, in the order of the profile section.
  public static let allCases: [ModelSlot] = [.standard, .flash, .embedding, .decision]

  /// The candidates of the slot in a profile.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The candidates, in order.
  func candidates(in profile: ProfileDefinition) -> [ModelRef] {
    switch self {
    case .standard: profile.standard
    case .flash: profile.flash
    case .embedding: profile.embedding
    case .decision: profile.decision
    }
  }
}

extension ProfileConfiguration {
  /// The key path of `profile` in the settings.
  static let keyPath = [AgentConfiguration.CodingKeys.profile.stringValue]
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

/// The reads of the `models` endpoint: the profile that `profile` selects at
/// the user level, the profile that the agent launched with, the model that
/// runs in each slot, the storage of each model, and the fit of each profile
/// of the user layer and the bundled profiles.
///
/// No read downloads a model or loads a model. Thus a host can make the
/// endpoint before the first download.
struct ModelsEngine: Sendable {
  /// The settings store. The engine reads the user level over the builtin
  /// layers, as the Settings scene of the app does.
  let store: SettingsStore

  /// The profile store. The engine lists, saves and deletes the profile
  /// files through it.
  let profileStore: ProfileStore

  /// Tells if the call runs in a child agent run, which cannot save or
  /// delete a profile (D193).
  let isChildRun: @Sendable () -> Bool

  /// The reader of the model storage.
  let storage: any ModelStorageSource

  /// The profile section that the running agent resolved at its launch, or
  /// `nil` when no agent runs yet.
  let launched: ProfileConfiguration?

  /// The model that runs in each slot, or none when no agent runs yet.
  let active: [ModelSlot: ModelRef]

  /// The source of the fit estimate of a profile, or `nil` when the fit is
  /// not known.
  let fitEstimator: (any ProfileFitEstimating)?

  /// The fit estimates that the engine read, by the name of the profile.
  let fitCache = ProfileFitCache()

  /// The profile files of the layers of the profile store.
  var profileLayers: ProfileLayers {
    profileStore.layers
  }

  /// The profile that `profile` selects in the settings now, at the user
  /// level.
  ///
  /// - Returns: The profile. The fallback profile of the store
  ///   (``SettingsStore/fallbackProfileName``) when no layer has a value,
  ///   or when the value names a profile that no layer has, as a load
  ///   does. A log record tells of the fallback of an unknown name.
  /// - Throws: What the store throws for a level file, the decode error of
  ///   a `profile` value that does not decode, and the error of a profile
  ///   file that does not read, as a load does. A log record tells of
  ///   each such error.
  func selectedProfile() async throws -> ProfileDefinition {
    guard let setting = try await store.value(at: ProfileConfiguration.keyPath, cwd: nil) else {
      return try fallbackProfile()
    }
    let selection: ProfileConfiguration
    do {
      selection = try setting.value.decoded()
    } catch {
      Self.logFailedRead(of: nil, error: error)
      throw error
    }
    do {
      return try profileLayers.read(selection.name, cwd: nil)
    } catch ProfileStoreError.unknownProfile(let name, _) {
      ACPAgentTelemetry.logger(.configuration).warning(
        "No layer has the selected profile. The models endpoint uses the fallback profile.",
        metadata: [ACPAgentTelemetry.LogMetadataKey.profileName: "\(name)"])
      return try fallbackProfile()
    } catch {
      Self.logFailedRead(of: selection.name, error: error)
      throw error
    }
  }

  /// The profile of the fallback name of the store.
  ///
  /// - Returns: The profile.
  /// - Throws: The error of a profile file of that name that does not
  ///   read. A log record tells of the error. A fallback name that no
  ///   layer has is a programmer error, because the fallback name is a
  ///   bundled name: it also stops a debug build.
  private func fallbackProfile() throws -> ProfileDefinition {
    let name = store.fallbackProfileName
    do {
      return try profileLayers.read(name, cwd: nil)
    } catch {
      if case ProfileStoreError.unknownProfile = error {
        assertionFailure("the fallback profile \(name) is not a bundled profile")
      }
      Self.logFailedRead(of: name, error: error)
      throw error
    }
  }

  /// Writes the log record of a read of the selected profile that failed.
  /// The record holds the key path, the name of the profile and the case
  /// of the error, never a value of the settings, because a value can be a
  /// secret.
  ///
  /// - Parameters:
  ///   - name: The name of the profile, or `nil` when the `profile` value
  ///     did not decode.
  ///   - error: The error of the read.
  private static func logFailedRead(of name: String?, error: any Error) {
    var metadata = ACPAgentTelemetry.errorMetadata(error)
    metadata[ACPAgentTelemetry.LogMetadataKey.configSection] =
      "\(ProfileConfiguration.keyPath.joined(separator: "."))"
    metadata[ACPAgentTelemetry.LogMetadataKey.errorCase] =
      "\(ACPAgentTelemetry.errorCaseName(of: error))"
    if let name {
      metadata[ACPAgentTelemetry.LogMetadataKey.profileName] = "\(name)"
    }
    ACPAgentTelemetry.logger(.configuration).error(
      "The models endpoint cannot read the selected profile.", metadata: metadata)
  }

  /// Each profile of the user layer and the bundled profiles that reads, in
  /// the order of the list.
  var availableProfiles: [ProfileDefinition] {
    profileLayers.list(cwd: nil).compactMap(\.profile)
  }

  /// The candidates of a slot in the selected profile.
  ///
  /// - Parameter slot: The slot.
  /// - Returns: The candidates, in order.
  /// - Throws: What the store throws for a level file.
  func candidates(of slot: ModelSlot) async throws -> [ModelRef] {
    slot.candidates(in: try await selectedProfile())
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
    return slot.candidates(in: launched.definition) != candidates
  }

  /// The name of the profile that `profile` selects now, at the user
  /// level.
  ///
  /// - Returns: The name.
  /// - Throws: What the store throws for a level file.
  func selectedName() async throws -> String {
    try await selectedProfile().name
  }

  /// One row of each available profile that reads, in the order of the
  /// list.
  ///
  /// - Parameter cwd: The working directory of the project layer, or `nil`
  ///   for the user layer and the bundled profiles.
  /// - Returns: The rows.
  /// - Throws: What the store throws for a level file.
  func profiles(cwd: URL?) async throws -> [ModelsGraphProfile] {
    let selected = try await selectedName()
    var rows: [ModelsGraphProfile] = []
    for entry in profileLayers.list(cwd: cwd) {
      guard let profile = entry.profile else { continue }
      rows.append(await row(of: profile, layer: entry.layer, selected: selected))
    }
    return rows
  }

  /// Saves a profile file through the profile store, and gives its row.
  ///
  /// - Parameters:
  ///   - name: The name of the profile.
  ///   - keys: The keys of the profile file.
  ///   - layer: The layer of the file.
  ///   - cwd: The working directory of the project layer, or `nil`.
  /// - Returns: The row of the saved profile.
  /// - Throws: ``ModelsGraphError``, or what the store throws.
  func saveProfile(name: String, keys: YAMLValue, layer: ModelsGraphProfileLayer, cwd: URL?)
    async throws -> ModelsGraphProfile
  {
    try refuseChildRun()
    let level = try layer.level(cwd: cwd)
    guard case .dictionary = keys else {
      throw ModelsGraphError.invalidProfile(detail: "the profile must be an object of keys")
    }
    let text = try ConfigurationYAML.levelText(of: keys)
    try await ModelsGraphError.withCodedErrors {
      try await profileStore.save(text: text, as: name, level: level)
    }
    let profile = try await ModelsGraphError.withCodedErrors { try profileLayers.read(name, cwd: cwd) }
    return await row(of: profile, layer: ProfileLayer(level), selected: try await selectedName())
  }

  /// Deletes a profile file through the profile store.
  ///
  /// - Parameters:
  ///   - name: The name of the profile.
  ///   - layer: The layer of the file.
  ///   - cwd: The working directory of the project layer, or `nil`.
  /// - Throws: ``ModelsGraphError``, or what the store throws.
  func deleteProfile(name: String, layer: ModelsGraphProfileLayer, cwd: URL?) async throws {
    try refuseChildRun()
    let level = try layer.level(cwd: cwd)
    try await ModelsGraphError.withCodedErrors {
      try await profileStore.delete(name, level: level)
    }
  }

  /// Refuses a profile change from a child agent run (D193).
  ///
  /// - Throws: ``ModelsGraphError/childRun`` in a child run.
  private func refuseChildRun() throws {
    if isChildRun() {
      throw ModelsGraphError.childRun
    }
  }

  /// The row of one profile.
  ///
  /// - Parameters:
  ///   - profile: The profile.
  ///   - layer: The layer of its file.
  ///   - selected: The name of the selected profile.
  /// - Returns: The row.
  private func row(of profile: ProfileDefinition, layer: ProfileLayer, selected: String) async
    -> ModelsGraphProfile
  {
    var models: [ModelsGraphProfileModel] = []
    var reports: [String: ModelsReport] = [:]
    for slot in ModelSlot.allCases {
      guard let ref = slot.candidates(in: profile).first else {
        continue
      }
      let report = await reports[ref.stringValue].asyncDefault { await self.report(of: ref) }
      reports[ref.stringValue] = report
      models.append(
        ModelsGraphProfileModel(slot: ModelsGraphSlot(slot), model: ModelsGraphModelFields(report)))
    }
    let parts = Array(reports.values)
    let sizes = parts.map(\.sizeBytes)
    let present = parts.reduce(Int64(0)) { $0 + $1.presentBytes }
    let estimate = await fit(of: profile)
    let launchedName = launched?.definition.name
    return ModelsGraphProfile(
      name: profile.name, layer: ModelsGraphProfileLayer(layer), description: profile.description,
      selected: profile.name == selected,
      active: profile.name == launchedName,
      restartRequired: launchedName != nil && profile.name == selected && selected != launchedName,
      models: models,
      downloadBytes: sizes.contains(nil) ? nil : Double(sizes.compactMap { $0 }.reduce(0, +)),
      presentBytes: Double(present),
      state: Self.state(of: parts, present: present),
      fit: ModelsGraphProfileFit(estimate),
      requiredBytes: estimate?.requiredBytes.map(Double.init),
      budgetBytes: estimate.map { Double($0.budgetBytes) },
      fitError: estimate?.failure,
      contextTokens: estimate?.contextTokens,
      targetMemory: layer == .bundled ? BundledProfiles.targetMemory(of: profile.name) : nil)
  }

  /// The disk state of a profile: complete when each model is complete,
  /// missing when no byte is on disk, else partial.
  ///
  /// - Parameters:
  ///   - parts: The reports of the different models of the profile.
  ///   - present: The bytes of the models on disk.
  /// - Returns: The state.
  private static func state(of parts: [ModelsReport], present: Int64) -> ModelsGraphDiskState {
    if !parts.isEmpty, parts.allSatisfy({ $0.state == .complete }) {
      return .complete
    }
    return present == 0 ? .missing : .partial
  }

  /// The fit estimate of a profile, from the cache when the engine read it
  /// before.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The estimate, or `nil` when the engine has no estimator.
  func fit(of profile: ProfileDefinition) async -> ProfileFitReport? {
    guard let fitEstimator else {
      return nil
    }
    if let cached = await fitCache.value(of: profile.name) {
      return cached
    }
    let estimate = await fitEstimator.fitReport(of: profile)
    await fitCache.set(estimate, of: profile.name)
    return estimate
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

  /// Each different model of the bundled profiles, in the order of the
  /// profiles and their slots.
  static var builtinModels: [ModelRef] {
    models(of: BundledProfiles.all)
  }

  /// Each different model of some profiles, in the order of the profiles
  /// and their slots.
  ///
  /// - Parameter profiles: The profiles.
  /// - Returns: The models.
  static func models(of profiles: [ProfileDefinition]) -> [ModelRef] {
    var seen = Set<String>()
    return profiles.flatMap { profile in
      ModelSlot.allCases.flatMap { $0.candidates(in: profile) }
    }.filter { seen.insert($0.stringValue).inserted }
  }

  /// A short text of the disk state of each model of the available
  /// profiles, by the text form of the model. The change feed compares two
  /// of them to find a model that came on disk.
  ///
  /// - Returns: The text of each model.
  func diskFingerprint() async -> [String: String] {
    var texts: [String: String] = [:]
    for ref in Self.models(of: availableProfiles) {
      let report = await report(of: ref)
      texts[ref.stringValue] = "\(report.state):\(report.presentBytes)"
    }
    return texts
  }

  /// The slots of the selected profile whose model is in a set.
  ///
  /// - Parameter models: The text forms of the models.
  /// - Returns: The slots, in order. Each slot when the selected profile
  ///   does not read, so that a subscriber reads the endpoint again and
  ///   gets the error. A log record tells of the error.
  func slots(holding models: Set<String>) async -> [ModelSlot] {
    let profile: ProfileDefinition
    do {
      profile = try await selectedProfile()
    } catch {
      ACPAgentTelemetry.logger(.configuration).warning(
        "The selected profile does not read. The disk change names each slot.",
        metadata: ACPAgentTelemetry.errorMetadata(error))
      return ModelSlot.allCases
    }
    return ModelSlot.allCases.filter { slot in
      slot.candidates(in: profile).contains { models.contains($0.stringValue) }
    }
  }
}

/// The fit estimates that a `models` endpoint read, by the name of the
/// profile. A change of the settings or of the disk clears it.
actor ProfileFitCache {
  /// The estimates.
  private var estimates: [String: ProfileFitReport] = [:]

  /// The estimate of a profile.
  ///
  /// - Parameter name: The name of the profile.
  /// - Returns: The estimate, or `nil` when the cache has none.
  func value(of name: String) -> ProfileFitReport? {
    estimates[name]
  }

  /// Keeps the estimate of a profile.
  ///
  /// - Parameters:
  ///   - estimate: The estimate.
  ///   - name: The name of the profile.
  func set(_ estimate: ProfileFitReport, of name: String) {
    estimates[name] = estimate
  }

  /// Forgets each estimate.
  func clear() {
    estimates = [:]
  }
}

extension Optional {
  /// The wrapped value, or the value of an async function.
  ///
  /// - Parameter fallback: The function.
  /// - Returns: The value.
  fileprivate func asyncDefault(_ fallback: () async -> Wrapped) async -> Wrapped {
    switch self {
    case .some(let value): value
    case .none: await fallback()
    }
  }
}
