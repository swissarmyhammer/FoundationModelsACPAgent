import Foundation
import FoundationModelsRouter

/// A configuration section whose keys the loader checks before the decode:
/// an unknown key inside the section is an error. The
/// section's `CodingKeys` is the one list of known keys, so the check and
/// the decode cannot drift apart.
protocol KeyCheckedSection {
  /// The section's coding keys, enumerable so the loader can list them.
  associatedtype CodingKeys: CodingKey & CaseIterable
}

extension KeyCheckedSection {
  /// Every key the section decodes, by its YAML spelling.
  static var knownKeys: Set<String> {
    Set(CodingKeys.allCases.map(\.stringValue))
  }
}

/// The `config.yaml` schema. Layer 1 of the stack is
/// the builtin file `builtin.config.yaml`, which names each tool and
/// its defaults. The property defaults of this type and its sections are the
/// decode fallback: a section or a key that no layer sets keeps its default.
/// A test makes sure that the builtin file decodes to exactly
/// `AgentConfiguration()`.
///
/// There is no `permissions` section and no `sandbox` section: the agent
/// asks for no permission, and the shell runs with no sandbox.
/// There is no `instructions` section: the system prompt is the markdown
/// file `Instructions.md`. There is no context-size key: the context comes
/// from the model, and the profile decides the context of the decision slot.
public struct AgentConfiguration: Codable, Equatable, Sendable {
  /// The model profile: the name of the profile file that selects the
  /// models of the `standard`, `flash`, `embedding` and `decision` slots.
  public var profile = ProfileConfiguration()

  /// The tool roster: per-tool enable and disable through the
  /// section codec, plus the `mcp:` server list.
  public var tools = ToolsConfiguration()

  /// The thresholds of the self-folding session's token budget.
  public var compaction = CompactionConfiguration()

  /// The settings of Router's repetition detector (task ^k51h6bb).
  public var repetition = RepetitionConfiguration()

  /// The appearance that a host applies. The agent does not read it: it
  /// keeps the key in the settings stack for the host.
  public var theme = AgentTheme.system

  /// The key bindings of the editor of a host. The agent does not read it:
  /// it keeps the key in the settings stack for the host.
  public var keymap = AgentKeymap.cua

  /// The fonts that a host applies to each role. The agent does not read
  /// it: it keeps the section in the settings stack for the host.
  public var fonts = FontsConfiguration()

  /// The status line of the chat header of a host (``StatusLineConfiguration``).
  /// The agent does not read it.
  public var statusline = StatusLineConfiguration()

  /// The YAML spelling of each top-level section.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case profile, tools, compaction, repetition, theme, keymap, fonts, statusline
  }

  /// The top-level sections that the configuration had before D187:
  /// `recording` (`level`) and `transcripts` (`location`). Each session
  /// records its full transcript in its project, at
  /// `<cwd>/.<name>/transcripts/`, so no key moves or turns off the
  /// transcripts. A layer that has one of these sections loads: each key
  /// gives a warning, and the agent ignores it.
  public static let retiredSections: Set<String> = ["recording", "transcripts"]

  /// The builtin configuration: every section at its default.
  public init() {}

  /// Decodes each present section and keeps the default for each absent
  /// or null one.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    profile = try container.decodeIfPresent(ProfileConfiguration.self, forKey: .profile) ?? profile
    tools = try container.decodeIfPresent(ToolsConfiguration.self, forKey: .tools) ?? tools
    compaction =
      try container.decodeIfPresent(CompactionConfiguration.self, forKey: .compaction)
      ?? compaction
    repetition =
      try container.decodeIfPresent(RepetitionConfiguration.self, forKey: .repetition)
      ?? repetition
    theme = try container.decodeIfPresent(AgentTheme.self, forKey: .theme) ?? theme
    keymap = try container.decodeIfPresent(AgentKeymap.self, forKey: .keymap) ?? keymap
    fonts = try container.decodeIfPresent(FontsConfiguration.self, forKey: .fonts) ?? fonts
    statusline =
      try container.decodeIfPresent(StatusLineConfiguration.self, forKey: .statusline)
      ?? statusline
  }
}

extension AgentConfiguration {
  /// How the loader treats the keys under one top-level section.
  enum SectionSchema: Equatable, Sendable {
    /// The section decodes exactly these keys; any other key is an error.
    case checked(Set<String>)
    /// The section decodes the `known` keys. A `retired` key gives a
    /// warning, and the decode ignores it. Any other key is an error.
    case checkedWithRetired(known: Set<String>, retired: Set<String>)
    /// The `tools:` roster: a known tool's body keys are
    /// checked, and an unknown tool key is a warning only.
    case toolRoster
    /// One value and no keys. The decode of the section checks the value.
    case scalar
    /// A section that the configuration no longer has
    /// (``AgentConfiguration/retiredSections``). Each key gives a warning,
    /// and the decode ignores the section.
    case retired
  }

  /// The schema of every top-level section, by its YAML spelling. A
  /// top-level key absent from this table is an unknown section, which
  /// the loader reports as a warning.
  static let sectionSchemas: [String: SectionSchema] = [
    CodingKeys.profile.stringValue: .checkedWithRetired(
      known: ProfileConfiguration.knownKeys, retired: ProfileConfiguration.retiredKeys),
    CodingKeys.tools.stringValue: .toolRoster,
    "recording": .retired,
    "transcripts": .retired,
    CodingKeys.compaction.stringValue: .checked(CompactionConfiguration.knownKeys),
    CodingKeys.repetition.stringValue: .checked(RepetitionConfiguration.knownKeys),
    CodingKeys.theme.stringValue: .scalar,
    CodingKeys.keymap.stringValue: .scalar,
    CodingKeys.fonts.stringValue: .checked(FontsConfiguration.knownKeys),
    CodingKeys.statusline.stringValue: .checked(StatusLineConfiguration.topKeys),
  ]
}

// MARK: - theme and keymap

/// A top-level key whose value is one word from a fixed list.
///
/// The decode ignores case, because a host shows the choices with a capital
/// letter (`System`, `Vim`). Each other value is an error that names the
/// choices, thus the settings store refuses it before it writes a file.
protocol CaseInsensitiveChoice: RawRepresentable, CaseIterable, Decodable
where RawValue == String {
  /// The YAML spelling of the key, for the error text.
  static var keyName: String { get }
}

extension CaseInsensitiveChoice {
  /// Decodes one choice, in any case.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let word = try container.decode(String.self)
    guard let choice = Self(rawValue: word.lowercased()) else {
      let choices = Self.allCases.map(\.rawValue).joined(separator: ", ")
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "\(Self.keyName) must be one of: \(choices) (got \"\(word)\")")
    }
    self = choice
  }
}

/// The top-level `theme` key: `system`, `light` or `dark`.
public enum AgentTheme: String, Codable, CaseIterable, Sendable, CaseInsensitiveChoice {
  /// Follow the appearance of the system.
  case system

  /// The light appearance.
  case light

  /// The dark appearance.
  case dark

  static var keyName: String { AgentConfiguration.CodingKeys.theme.stringValue }
}

/// The top-level `keymap` key: `cua`, `vim` or `emacs`.
public enum AgentKeymap: String, Codable, CaseIterable, Sendable, CaseInsensitiveChoice {
  /// The standard key bindings of the platform (Common User Access).
  case cua

  /// The Vim key bindings.
  case vim

  /// The Emacs key bindings.
  case emacs

  static var keyName: String { AgentConfiguration.CodingKeys.keymap.stringValue }
}

// MARK: - fonts

/// The `fonts:` section: the font of each role of a host. The agent does not
/// read it.
///
/// Each role is optional. An absent family or size means that the host uses
/// its own default.
public struct FontsConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The font of the controls of the host.
  public var ui = FontRoleConfiguration()

  /// The font of the large text of the host, for example the titles.
  public var display = FontRoleConfiguration()

  /// The font of the code and of the terminal.
  public var code = FontRoleConfiguration()

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case ui, display, code
  }

  /// The default: each role uses the default of the host.
  public init() {}

  /// Decodes each present role and keeps the default for each absent role.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ui = try container.decodeIfPresent(FontRoleConfiguration.self, forKey: .ui) ?? ui
    display =
      try container.decodeIfPresent(FontRoleConfiguration.self, forKey: .display) ?? display
    code = try container.decodeIfPresent(FontRoleConfiguration.self, forKey: .code) ?? code
  }
}

/// The font of one role under `fonts:`: a family and a size in points.
///
/// The section check of the loader looks at the role names only, thus the
/// decode of a role refuses each key that is not `family` or `size`.
public struct FontRoleConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The name of the font family. When nil, the host uses its default.
  public var family: String?

  /// The size in points. When nil, the host uses its default.
  public var size: Double?

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case family, size
  }

  /// A role with the given family and size.
  ///
  /// - Parameters:
  ///   - family: The name of the font family, or nil for the default.
  ///   - size: The size in points, or nil for the default.
  public init(family: String? = nil, size: Double? = nil) {
    self.family = family
    self.size = size
  }

  /// Decodes `family` and `size` when present, and refuses each other key.
  public init(from decoder: any Decoder) throws {
    let unknown = try decoder.container(keyedBy: AnyCodingKey.self).allKeys
      .map(\.stringValue).filter { !Self.knownKeys.contains($0) }.sorted()
    if let first = unknown.first {
      let choices = CodingKeys.allCases.map(\.stringValue).joined(separator: ", ")
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "unknown font key \"\(first)\"; the keys are: \(choices)"))
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    family = try container.decodeIfPresent(String.self, forKey: .family)
    size = try container.decodeIfPresent(Double.self, forKey: .size)
    if let size, !(size > 0) {
      throw DecodingError.dataCorruptedError(
        forKey: .size, in: container, debugDescription: "a font size must be more than 0")
    }
  }
}

// MARK: - profile

/// The `profile` key: the name of the profile file that selects the models
/// of the agent, such as `profile: large`.
///
/// A profile is a file, `profiles/<name>.yaml`, in the project layer, the
/// user layer or the bundled resources (``ProfileStore``). The loader reads
/// the file of the name for the working directory of the load. For an
/// unknown name, the load gives a warning that lists every available name,
/// and it uses the fallback profile (``BundledProfiles/fallbackName()``).
///
/// The old map form of the section loads: its `preset` key gives the name,
/// and each other key (``retiredKeys``) gives a warning and is ignored.
public struct ProfileConfiguration: Codable, Equatable, Sendable {
  /// The key of the old map form that gives the name.
  public static let presetKey = "preset"

  /// The known keys of the old map form: ``presetKey``.
  public static let knownKeys: Set<String> = [presetKey]

  /// The keys of the old map form that the agent no longer reads. A layer
  /// that has one of them gives a warning, and the agent ignores the key.
  public static let retiredKeys: Set<String> = [
    "name", "description", "standard", "flash", "embedding", "decision", "decisionContext",
    "kvBits",
  ]

  /// The name of the selected profile.
  public var name = BundledProfiles.defaultName

  /// The profile that the loader read for ``name``, or a profile that a
  /// test sets in code. It is not a key of the settings. `nil` gives the
  /// bundled profile of the name.
  var resolved: ProfileDefinition?

  /// The default profile.
  public init() {}

  /// The profile of a name.
  ///
  /// - Parameter name: The name of the profile.
  public init(name: String) {
    self.name = name
  }

  /// Decodes the name: a string, or the old map form, whose `preset` gives
  /// the name and whose other keys are ignored.
  ///
  /// - Throws: `DecodingError` when the value is neither a string nor a
  ///   mapping, or when `preset` is not a string.
  public init(from decoder: any Decoder) throws {
    if let name = try? decoder.singleValueContainer().decode(String.self) {
      self.name = name
      return
    }
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    name = try container.decodeIfPresent(String.self, forKey: AnyCodingKey(stringValue: Self.presetKey))
      ?? name
  }

  /// Encodes the name as one string.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(name)
  }

  /// The selected profile: the profile that the loader read, else the
  /// bundled profile of the name, else the default profile.
  public var definition: ProfileDefinition {
    resolved ?? BundledProfiles.named(name) ?? BundledProfiles.defaultProfile
  }

  /// Two sections are equal when their names are equal and their profiles
  /// have the same encoding. `ProfileDefinition` is not `Equatable`.
  public static func == (lhs: ProfileConfiguration, rhs: ProfileConfiguration) -> Bool {
    lhs.name == rhs.name && encoding(of: lhs.definition) == encoding(of: rhs.definition)
  }

  /// The JSON encoding of a profile, with sorted keys.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The encoding, or `nil` when it fails.
  private static func encoding(of profile: ProfileDefinition) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try? encoder.encode(profile)
  }
}

/// A coding key that holds any key of a mapping: the unknown keys of a font
/// role, and the `preset` key of the old map form of `profile`.
private struct AnyCodingKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

// MARK: - compaction

/// The `compaction:` section: the fractions and caps of Router's
/// `TokenBudget`. The budget's `limit` is not here: the context size comes
/// from the model.
public struct CompactionConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The default fraction of the context at which a session folds.
  public static let defaultTrigger = 0.80

  /// The default fraction of the context a fold compacts down to.
  public static let defaultTarget = 0.50

  /// The fraction of the context at which a session folds.
  public var trigger = CompactionConfiguration.defaultTrigger

  /// The fraction of the context a fold compacts down to.
  public var target = CompactionConfiguration.defaultTarget

  /// The optional hard ceiling, as a fraction of the context.
  public var hardCeiling: Double?

  /// The optional cap, in tokens, on one tool result.
  public var toolOutputLimit: Int?

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case trigger, target, hardCeiling, toolOutputLimit
  }

  /// The default thresholds: fold at 80 percent, down to 50 percent, with
  /// no hard ceiling and no tool output cap.
  public init() {}

  /// Decodes each present key and keeps the default for each absent one.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    trigger = try container.decodeIfPresent(Double.self, forKey: .trigger) ?? trigger
    target = try container.decodeIfPresent(Double.self, forKey: .target) ?? target
    hardCeiling = try container.decodeIfPresent(Double.self, forKey: .hardCeiling)
    toolOutputLimit = try container.decodeIfPresent(Int.self, forKey: .toolOutputLimit)
  }
}
