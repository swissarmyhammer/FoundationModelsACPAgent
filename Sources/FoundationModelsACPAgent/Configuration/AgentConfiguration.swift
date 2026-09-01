import Foundation
import FoundationModelsRouter

/// A configuration section whose keys the loader checks before the decode
/// (plan.md §2.4): an unknown key inside the section is an error. The
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

/// The `config.yaml` schema (plan.md §2.4). The property defaults of this
/// type and its sections ARE the builtin configuration, layer 1 of the
/// stack (§2.2): there is no shipped `config.yaml` and no defaults
/// directory. A missing section or key keeps its default.
///
/// There is no `permissions` section: the sandbox is the only gate (§11.7).
/// There is no `instructions` section: the system prompt is a markdown file
/// (§3.1). There is no context-size key: the context comes from the model.
public struct AgentConfiguration: Codable, Equatable, Sendable {
    /// The model profile: the `standard`, `flash` and `embedding` slots.
    public var profile = ProfileConfiguration()

    /// The tool roster (§11.2). Its body decodes in the codec task; until
    /// then the section is open and its keys are not checked.
    public var tools = ToolsConfiguration()

    /// How much of each session is recorded.
    public var recording = RecordingConfiguration()

    /// Where transcripts are written (§4.1).
    public var transcripts = TranscriptsConfiguration()

    /// The thresholds of the self-folding session's token budget.
    public var compaction = CompactionConfiguration()

    /// The sandbox section (§11.7). Its body decodes in the codec task;
    /// until then the section is open and its keys are not checked.
    public var sandbox = SandboxConfiguration()

    /// The YAML spelling of each top-level section.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case profile, tools, recording, transcripts, compaction, sandbox
    }

    /// The builtin configuration: every section at its default.
    public init() {}

    /// Decodes each present section and keeps the default for each absent
    /// or null one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(ProfileConfiguration.self, forKey: .profile) ?? profile
        tools = try container.decodeIfPresent(ToolsConfiguration.self, forKey: .tools) ?? tools
        recording =
            try container.decodeIfPresent(RecordingConfiguration.self, forKey: .recording)
            ?? recording
        transcripts =
            try container.decodeIfPresent(TranscriptsConfiguration.self, forKey: .transcripts)
            ?? transcripts
        compaction =
            try container.decodeIfPresent(CompactionConfiguration.self, forKey: .compaction)
            ?? compaction
        sandbox = try container.decodeIfPresent(SandboxConfiguration.self, forKey: .sandbox) ?? sandbox
    }
}

extension AgentConfiguration {
    /// How the loader treats the keys under one top-level section.
    enum SectionSchema: Equatable, Sendable {
        /// The section decodes exactly these keys; any other key is an error.
        case checked(Set<String>)
        /// The section's body is not decoded yet, so no key is checked.
        case open
    }

    /// The schema of every top-level section, by its YAML spelling. A
    /// top-level key absent from this table is an unknown section, which
    /// the loader reports as a warning (§2.4).
    static let sectionSchemas: [String: SectionSchema] = [
        CodingKeys.profile.stringValue: .checked(ProfileConfiguration.knownKeys),
        CodingKeys.tools.stringValue: .open,
        CodingKeys.recording.stringValue: .checked(RecordingConfiguration.knownKeys),
        CodingKeys.transcripts.stringValue: .checked(TranscriptsConfiguration.knownKeys),
        CodingKeys.compaction.stringValue: .checked(CompactionConfiguration.knownKeys),
        CodingKeys.sandbox.stringValue: .open,
    ]
}

// MARK: - profile

/// The `profile:` section: the candidate models of each slot, in preference
/// order, and the profile's name. The defaults are a coding profile that
/// operates on a 16 GB machine (plan.md §2.2), the same profile Router's
/// README documents.
public struct ProfileConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// The default candidates of the `standard` slot.
    public static let defaultStandard: [ModelRef] = ["mlx-community/Qwen2.5-14B-Instruct-4bit"]

    /// The default candidates of the `flash` slot.
    public static let defaultFlash: [ModelRef] = ["mlx-community/Qwen2.5-3B-Instruct-4bit"]

    /// The default candidates of the `embedding` slot.
    public static let defaultEmbedding: [ModelRef] = ["mlx-community/bge-small-en-v1.5-4bit"]

    /// The default one-line description of the profile's intent.
    public static let defaultDescription = "Local coding assistant."

    /// The profile's name, or `nil` to fall back to the dotfolder name
    /// (plan.md §2.1).
    public var name: String?

    /// A short description of the profile's intent.
    public var description = ProfileConfiguration.defaultDescription

    /// Candidate models of the `standard` slot, in preference order.
    public var standard = ProfileConfiguration.defaultStandard

    /// Candidate models of the `flash` slot, in preference order.
    public var flash = ProfileConfiguration.defaultFlash

    /// Candidate models of the `embedding` slot, in preference order.
    public var embedding = ProfileConfiguration.defaultEmbedding

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case name, description, standard, flash, embedding
    }

    /// The default coding profile.
    public init() {}

    /// Decodes each present key and keeps the default for each absent one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? description
        standard = try container.decodeIfPresent([ModelRef].self, forKey: .standard) ?? standard
        flash = try container.decodeIfPresent([ModelRef].self, forKey: .flash) ?? flash
        embedding = try container.decodeIfPresent([ModelRef].self, forKey: .embedding) ?? embedding
    }
}

// MARK: - tools

/// The `tools:` section (plan.md §11.2). The codec task decodes its body;
/// until then any body is accepted and nothing is read from it.
public struct ToolsConfiguration: Codable, Equatable, Sendable {
    /// The default roster: every built-in on.
    public init() {}

    /// Accepts any body without reading it.
    public init(from decoder: any Decoder) throws {}
}

// MARK: - recording

/// The `recording:` section: how much of each session Router records.
public struct RecordingConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// The spelling YAML gives the word `off` once it resolves it as a
    /// boolean: `off`, `no` and `false` are one YAML 1.1 value, and the
    /// merged tree hands that value on as this string.
    private static let yamlBooleanOff = "false"

    /// The recording level. `full` by default (plan.md §2.2).
    public var level = RecordingLevel.full

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case level
    }

    /// The default: record everything.
    public init() {}

    /// Decodes `level`, accepting exactly Router's two levels, `off` and
    /// `full`. Any other value is an error that names both.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawLevel = try container.decodeIfPresent(String.self, forKey: .level) else {
            return
        }
        if rawLevel == Self.yamlBooleanOff {
            level = .off
            return
        }
        guard let parsedLevel = RecordingLevel(rawValue: rawLevel) else {
            let validLevels = RecordingLevel.allCases.map(\.rawValue).joined(separator: ", ")
            throw DecodingError.dataCorruptedError(
                forKey: .level, in: container,
                debugDescription:
                    "recording.level must be one of: \(validLevels) (got \"\(rawLevel)\")")
        }
        level = parsedLevel
    }
}

// MARK: - transcripts

/// Where a session's transcripts are written (plan.md §4.1).
public enum TranscriptLocation: Equatable, Sendable, Codable {
    /// `<cwd>/.<name>/transcripts/`, the project dotfolder. The default.
    case project
    /// A shared root under the home directory, with one slug per project.
    case home
    /// An absolute directory.
    case path(URL)

    /// The YAML word for `project`.
    private static let projectWord = "project"

    /// The YAML word for `home`.
    private static let homeWord = "home"

    /// The prefix that marks an absolute path.
    private static let absolutePathPrefix = "/"

    /// Decodes `project`, `home`, or an absolute path from one string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let word = try container.decode(String.self)
        switch word {
        case Self.projectWord:
            self = .project
        case Self.homeWord:
            self = .home
        case _ where word.hasPrefix(Self.absolutePathPrefix):
            self = .path(URL(fileURLWithPath: word, isDirectory: true))
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "transcripts.location must be \(Self.projectWord), \(Self.homeWord), "
                    + "or an absolute path (got \"\(word)\")")
        }
    }

    /// Encodes the same one string `init(from:)` reads.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .project:
            try container.encode(Self.projectWord)
        case .home:
            try container.encode(Self.homeWord)
        case .path(let url):
            try container.encode(url.path)
        }
    }
}

/// The `transcripts:` section.
public struct TranscriptsConfiguration: Codable, Equatable, Sendable, KeyCheckedSection {
    /// Where transcripts are written. Project-local by default (plan.md §2.2).
    public var location = TranscriptLocation.project

    /// The YAML spelling of each key.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case location
    }

    /// The default: project-local transcripts.
    public init() {}

    /// Decodes `location` when present and keeps the default otherwise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        location = try container.decodeIfPresent(TranscriptLocation.self, forKey: .location) ?? location
    }
}

// MARK: - compaction

/// The `compaction:` section: the fractions and caps of Router's
/// `TokenBudget`. The budget's `limit` is not here: the context size comes
/// from the model (plan.md §2.4).
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

// MARK: - sandbox

/// The `sandbox:` section (plan.md §11.7). The codec task decodes its body
/// into the sandbox options; until then any body is accepted and nothing is
/// read from it.
public struct SandboxConfiguration: Codable, Equatable, Sendable {
    /// The default: no extra write paths.
    public init() {}

    /// Accepts any body without reading it.
    public init(from decoder: any Decoder) throws {}
}
