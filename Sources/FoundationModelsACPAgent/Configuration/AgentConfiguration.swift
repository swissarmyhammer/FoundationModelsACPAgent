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
  /// The model profile: the builtin profile that selects the models of the
  /// `standard`, `flash`, `embedding` and `decision` slots.
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
    let unknown = try decoder.container(keyedBy: AnyFontKey.self).allKeys
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

  /// A coding key that holds each key of a role, to find the unknown keys.
  private struct AnyFontKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }
}

// MARK: - profile

/// The `profile:` section: the builtin profile that the agent resolves, and
/// the name of the profile (ACPA-21, D189).
///
/// The model configuration is by profile. `preset` names one profile of
/// ``ModelProfiles/builtin``, and that profile decides the model of each
/// slot and the context of the decision slot. The section has no slot key
/// and no context key. An old layer that still has one of
/// ``retiredKeys`` loads: the loader gives a warning for each such key, and
/// the agent ignores it.
///
/// The default profile is a coding profile that operates on a 32 GB machine
/// (cli-plan.md §7). A 27B model at 4 bits is approximately 15 GB on its own,
/// and Router's `JointFit` measures the four models together against the
/// memory budget.
public struct ProfileConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
  /// The default one-line description of the profile's intent.
  public static let defaultDescription = "Local coding assistant."

  /// The keys of the section before ACPA-21: the model of each slot and the
  /// context of the decision slot. A layer that has one of them gives a
  /// warning, and the agent ignores the key.
  public static let retiredKeys: Set<String> = [
    "standard", "flash", "embedding", "decision", "decisionContext",
  ]

  /// The profile's name, or `nil` to fall back to the dotfolder name. It is
  /// a label only: it does not select the models.
  public var name: String?

  /// A short description of the profile's intent. It is a label only: the
  /// resolved profile has the description of the preset.
  public var description = ProfileConfiguration.defaultDescription

  /// The name of the builtin profile that selects the models: one name of
  /// ``ModelProfiles/builtin``.
  public var preset = ModelProfiles.defaultName

  /// A profile that wins over ``preset``, for a test only. It is not a
  /// key of the settings: no layer can set it. A suite that needs models
  /// that no builtin profile has, such as a `flash` model that differs from
  /// the `standard` model, sets it in code.
  var testProfile: ProfileDefinition?

  /// The YAML spelling of each key.
  public enum CodingKeys: String, CodingKey, CaseIterable {
    case name, description, preset
  }

  /// The default coding profile.
  public init() {}

  /// Decodes each present key and keeps the default for each absent one.
  ///
  /// - Throws: `DecodingError` when `preset` names no builtin profile. The
  ///   error names each profile.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? description
    if let preset = try container.decodeIfPresent(String.self, forKey: .preset) {
      guard ModelProfiles.named(preset) != nil else {
        let names = ModelProfiles.builtin.map(\.name).joined(separator: ", ")
        throw DecodingError.dataCorruptedError(
          forKey: .preset, in: container,
          debugDescription: "profile.preset must be one of: \(names) (got \"\(preset)\")")
      }
      self.preset = preset
    }
  }

  /// The builtin profile that ``preset`` names. A value that names no
  /// profile, which only code can set, gives the default profile.
  public var presetProfile: ProfileDefinition {
    testProfile ?? ModelProfiles.named(preset) ?? ModelProfiles.defaultProfile
  }

  /// Two sections are equal when their keys are equal and their test
  /// profiles have the same encoding. `ProfileDefinition` is not
  /// `Equatable`.
  public static func == (lhs: ProfileConfiguration, rhs: ProfileConfiguration) -> Bool {
    lhs.name == rhs.name && lhs.description == rhs.description && lhs.preset == rhs.preset
      && encoding(of: lhs.testProfile) == encoding(of: rhs.testProfile)
  }

  /// The JSON encoding of a test profile, or `nil` for none.
  ///
  /// - Parameter profile: The profile.
  /// - Returns: The encoding.
  private static func encoding(of profile: ProfileDefinition?) -> Data? {
    profile.flatMap { try? JSONEncoder.sortedKeys.encode($0) }
  }
}

extension JSONEncoder {
  /// An encoder with sorted keys, so that two equal values give the same
  /// data.
  fileprivate static var sortedKeys: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
  }
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
