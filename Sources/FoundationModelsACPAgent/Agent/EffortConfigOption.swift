import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsRouter

extension ConfigOptions {
  /// The wire id of the reasoning effort select option (D218).
  static let effortOptionId = SessionConfigId(rawValue: "effort")

  /// The human-readable label of the reasoning effort option.
  private static let effortOptionName = "Reasoning Effort"

  /// The description of the reasoning effort option.
  private static let effortOptionDescription =
    "Selects how much the model of this session reasons before it answers. A change applies from the next turn."

  /// The reasoning effort select of one session (D218).
  ///
  /// The values are the levels that a session on the model can take
  /// (`ReasoningEffortLevels.sessionLevelNames`): each level of the model in
  /// the order of the probe, with the names of the model, then "Off" when
  /// the model has an Off level. The current value is the level of the
  /// session. A session whose model has no levels has no such select.
  struct EffortOption: Equatable, Sendable {
    /// The value id of the level of the session.
    let current: String

    /// The names of the levels, in announcement order.
    let levels: [String]

    /// The default level of the model.
    let defaultLevel: String

    /// Makes the reasoning effort select of a session.
    ///
    /// - Parameters:
    ///   - levels: The levels of the model of the session.
    ///   - level: The level of the session, or `nil` for the default level
    ///     of the model.
    /// - Returns: The select, or `nil` when the model has no levels.
    init?(levels: ReasoningEffortLevels, level: String?) {
      guard let defaultLevel = levels.defaultLevel, let current = levels.sessionLevel(for: level),
        !levels.sessionLevelNames.isEmpty
      else {
        return nil
      }
      self.current = current
      self.levels = levels.sessionLevelNames
      self.defaultLevel = defaultLevel
    }

    /// Makes the reasoning effort select of a live session: the levels of
    /// its model, and the level of its facts.
    ///
    /// - Parameter session: The Router session.
    /// - Returns: The select, or `nil` when the model of the session has no
    ///   levels.
    init?(session: any RoutedSession) {
      self.init(levels: session.reasoningEffortLevels, level: session.facts.reasoningEffort)
    }

    /// Tells if a set value names a level of the select.
    ///
    /// - Parameter value: The value id of a set request.
    /// - Returns: `true` when the value is a level.
    func contains(_ value: SessionConfigValueId) -> Bool {
      levels.contains(value.rawValue)
    }

    /// The wire option.
    var option: SessionConfigOption {
      SessionConfigOption(
        configId: ConfigOptions.effortOptionId,
        name: ConfigOptions.effortOptionName,
        category: .thoughtLevel,
        description: ConfigOptions.effortOptionDescription,
        type: .select(
          SessionConfigSelect(
            currentValue: SessionConfigValueId(rawValue: current),
            options: ConfigOptions.encodedSelectOptions(values))))
    }

    /// The values of the select: one value for each level. The name of a
    /// value is the name of the level, and the default level says so in its
    /// description.
    private var values: [SessionConfigSelectOption] {
      levels.map { level in
        SessionConfigSelectOption(
          name: level, value: SessionConfigValueId(rawValue: level),
          description: level == defaultLevel ? "The default level of the model." : nil)
      }
    }
  }

  /// The start level of a new root session for the `profiles.<name>.effort`
  /// setting (D218, ``ProfilesConfiguration``).
  ///
  /// - Parameters:
  ///   - setting: The value of the setting for the profile of the agent, or
  ///     `nil` when no layer sets it.
  ///   - levels: The levels of the model of the session.
  ///   - profileName: The name of the profile, for the warning.
  /// - Returns: The level to give to `SessionConfiguration(reasoningEffort:)`.
  ///   No value gives `nil`: the default level of the model. A value that
  ///   is not a level of the model gives `nil` and the warning
  ///   ``ConfigurationWarning/unknownEffort(profile:value:levels:defaultLevel:)``.
  static func startEffort(
    setting: String?, levels: ReasoningEffortLevels, profileName: String
  ) -> (level: String?, warning: ConfigurationWarning?) {
    guard let setting else {
      return (nil, nil)
    }
    guard levels.sessionLevelNames.contains(setting) else {
      return (
        nil,
        .unknownEffort(
          profile: profileName, value: setting, levels: levels.sessionLevelNames,
          defaultLevel: levels.defaultLevel)
      )
    }
    return (setting, nil)
  }
}
