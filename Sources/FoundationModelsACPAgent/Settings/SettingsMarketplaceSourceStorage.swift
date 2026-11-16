import Foundation
import FoundationModelsExtras
import FoundationModelsSkills

/// The storage port of the marketplace registry of Extras
/// (`MarketplaceSourceStorage`) over the settings of the agent: the list
/// `tools.skills.marketplaces` at the USER level (D190).
///
/// The registry changes one marketplace at a time and keeps the list
/// consistent; this port reads and writes the whole list. A write goes
/// through the settings store, thus it passes the schema check, it keeps the
/// template constructs of the file, and the store logs one change of the
/// list.
///
/// With no list in the settings, a load gives
/// ``SkillsToolOptions/defaultMarketplaces``: the list that a session reads.
/// The first save then writes the full list.
struct SettingsMarketplaceSourceStorage: MarketplaceSourceStorage {
  /// The key path of the list.
  static let keyPath = [
    AgentConfiguration.CodingKeys.tools.stringValue,
    ToolsConfiguration.CodingKeys.skills.stringValue,
    SkillsToolOptions.CodingKeys.marketplaces.stringValue,
  ]

  /// The settings store of the agent.
  let store: SettingsStore

  /// The sources of `tools.skills.marketplaces` at the USER level, in their
  /// stored order, or the default list when the settings have no list.
  ///
  /// - Returns: The sources.
  /// - Throws: What the store throws for the user file, or the decode
  ///   error of the list.
  func loadSources() async throws -> [MarketplaceSource] {
    guard let setting = try await store.value(at: Self.keyPath, cwd: nil) else {
      return SkillsToolOptions.defaultMarketplaces
    }
    return try setting.value.decoded()
  }

  /// Writes the sources to `tools.skills.marketplaces` at the USER level.
  ///
  /// - Parameter sources: The sources, in order.
  /// - Throws: What ``SettingsStore/set(_:at:level:)`` throws.
  func saveSources(_ sources: [MarketplaceSource]) async throws {
    try await store.set(.array(sources.map(\.yamlValue)), at: Self.keyPath, level: .user)
  }
}

extension MarketplaceSource {
  /// The source in the YAML form of one entry of
  /// `tools.skills.marketplaces`. An optional field is written only when it
  /// has a value; `select` only when it is not `all`, and `autoUpdate` only
  /// when it is off.
  var yamlValue: YAMLValue {
    var fields: [String: YAMLValue] = ["url": .string(url)]
    let optional: [(String, String?)] = [("ref", ref), ("sha", sha), ("path", path), ("alias", alias)]
    for (key, value) in optional {
      if let value {
        fields[key] = .string(value)
      }
    }
    if case .skills(let names) = select {
      fields["select"] = .dictionary(["skills": .array(names.map(YAMLValue.string))])
    }
    if !autoUpdate {
      fields["autoUpdate"] = .bool(false)
    }
    return .dictionary(fields)
  }
}
