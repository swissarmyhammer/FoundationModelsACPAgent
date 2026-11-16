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
/// A child agent run cannot change the list: a save and a reset from it
/// throw ``MarketplaceChangeRefusal/childRun`` (D193).
///
/// With no list in the settings, a load gives
/// ``SkillsToolOptions/defaultMarketplaces``: the list that a session reads.
/// The first save then writes the full list, and a reset clears it again.
struct SettingsMarketplaceSourceStorage: MarketplaceSourceStorage {
  /// The key path of the list.
  static let keyPath = [
    AgentConfiguration.CodingKeys.tools.stringValue,
    ToolsConfiguration.CodingKeys.skills.stringValue,
    SkillsToolOptions.CodingKeys.marketplaces.stringValue,
  ]

  /// The text of the refusal of a change from a child agent run.
  static let childRunRefusal =
    "A child agent run cannot change the marketplace list: it is configuration of the user. "
    + "Use `list marketplace` or `show marketplace` to read it, and ask the user or the parent "
    + "session to change it."

  /// The settings store of the agent.
  let store: SettingsStore

  /// Tells if the call runs in a child agent run: a tool call whose session
  /// has a parent session. A test gives its own answer.
  var isChildRun: @Sendable () -> Bool = { ToolContext.current?.parentSessionID != nil }

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
    try refuseChildRun()
    try await store.set(.array(sources.map(\.yamlValue)), at: Self.keyPath, level: .user)
  }

  /// Clears `tools.skills.marketplaces` at the USER level, and gives the
  /// list that applies after that: the list of the defaults layer, else
  /// ``SkillsToolOptions/defaultMarketplaces``.
  ///
  /// The registry of the agent has no working directory, thus the answer
  /// has no project list. Each session reads its merged list again after
  /// the change (``MarketplaceMount``), so a project list still applies
  /// in its session.
  ///
  /// - Returns: The list after the reset.
  /// - Throws: What ``SettingsStore/clear(at:level:)`` throws, or the load
  ///   error of the list.
  func resetSources() async throws -> [MarketplaceSource] {
    try refuseChildRun()
    try await store.clear(at: Self.keyPath, level: .user)
    return try await loadSources()
  }
}

extension SettingsMarketplaceSourceStorage {
  /// Refuses a change from a child agent run (D193). The marketplace list
  /// is configuration of the user, as the MCP servers are, and a child run
  /// has no `mcpServers` tool either. The read operations still work.
  ///
  /// - Throws: ``MarketplaceChangeRefusal/childRun`` in a child run.
  func refuseChildRun() throws {
    if isChildRun() {
      throw MarketplaceChangeRefusal.childRun
    }
  }
}

/// Why the agent refused a change of the marketplace list.
enum MarketplaceChangeRefusal: Error, Equatable, LocalizedError, CustomStringConvertible {
  /// The change came from a child agent run.
  case childRun

  /// The corrective text for the model.
  var errorDescription: String? {
    SettingsMarketplaceSourceStorage.childRunRefusal
  }

  /// The corrective text for the model.
  var description: String {
    SettingsMarketplaceSourceStorage.childRunRefusal
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
