import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The reasoning effort levels of each model that an agent of this machine
/// loaded (D218), by the text form of the model reference
/// (`ModelRef.stringValue`).
///
/// The probe of the chat template finds the levels of a model when the
/// model loads. The `models` endpoint must also give the levels of the
/// `standard` model of a profile that is not loaded now, so that the
/// Settings scene of a host can show the default reasoning effort of each
/// profile. Thus the agent records the levels of its resident models in a
/// JSON file of the state of this machine (``AgentHome/reasoningEffortLevelsFile``),
/// and the endpoint reads that file. A model gives its levels after its
/// first load on this machine. A model that no agent loaded has no record.
///
/// A record of a model with no levels holds empty levels: the endpoint then
/// tells that the model has no levels, which differs from a model with no
/// record.
public struct ReasoningEffortLevelsRecord: Sendable {
  /// The file of the record.
  public let fileURL: URL

  /// Makes a record over a file.
  ///
  /// - Parameter fileURL: The JSON file of the record. The file does not
  ///   have to exist: a record with no file holds no levels.
  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  /// The levels of each recorded model, by the text form of its reference.
  ///
  /// A file that is not there gives no levels. A file that cannot be read
  /// or decoded gives no levels and a warning in the log, because the
  /// levels only help a client: the endpoint then gives no levels.
  ///
  /// - Returns: The levels of each recorded model.
  public func levels() -> [String: ReasoningEffortLevels] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return [:]
    }
    do {
      return try JSONDecoder().decode(
        [String: ReasoningEffortLevels].self, from: Data(contentsOf: fileURL))
    } catch {
      ACPAgentTelemetry.logger(.configuration).warning(
        "The record of the reasoning effort levels cannot be read. The models endpoint gives no levels.",
        metadata: ACPAgentTelemetry.errorMetadata(error))
      return [:]
    }
  }

  /// Adds the levels of some models to the record, and writes the file
  /// when the record changes. The levels of a model replace its old record.
  /// The record of each other model stays.
  ///
  /// A write that fails gives a warning in the log, and the agent
  /// continues: the endpoint then gives the levels that the file had.
  ///
  /// - Parameter recorded: The levels of each model, by the text form of
  ///   its reference.
  public func record(_ recorded: [String: ReasoningEffortLevels]) {
    let old = levels()
    let new = old.merging(recorded) { _, newLevels in newLevels }
    guard new != old else {
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      try encoder.encode(new).write(to: fileURL, options: .atomic)
    } catch {
      ACPAgentTelemetry.logger(.configuration).warning(
        "The record of the reasoning effort levels cannot be written. The models endpoint keeps the old levels.",
        metadata: ACPAgentTelemetry.errorMetadata(error))
    }
  }

  /// The levels of the chat models of a resident profile: its `standard`
  /// and `flash` models, by the text form of the reference of each one.
  ///
  /// - Parameter profile: The resident profile.
  /// - Returns: The levels of each chat model of the profile.
  public static func levels(of profile: LanguageModelProfile) -> [String: ReasoningEffortLevels] {
    Dictionary(
      ConfigOptions.selectableSlots.map { slot in
        let handle = ConfigOptions.handle(for: slot, of: profile)
        return (handle.chosen.stringValue, handle.reasoningEffortLevels)
      },
      uniquingKeysWith: { first, _ in first })
  }
}
