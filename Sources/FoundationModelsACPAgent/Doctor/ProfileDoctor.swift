import Foundation
import FoundationModelsExtras
import FoundationModelsRouter

/// The `doctor` component of the profile (cli-plan.md §5.12, row 2): each
/// model reference is well formed, each one resolves at Hugging Face, the
/// cache state says whether the next run downloads, the trio fits the
/// memory of the machine, the free disk covers the download, and a slot
/// that names an MTP build warns.
///
/// Every fact from outside is injected: a ``ModelResolver`` for the Hub
/// and the cache, the memory of the machine, and the free disk. So no unit
/// test asks the network, no unit test reads the model cache, and no
/// finding changes from one host to the next. Every resolver call runs
/// under ``resolveTimeoutSeconds``, so one repository that stopped
/// answering cannot hold the whole report.
///
/// Nothing here throws. A reference that does not resolve is one finding
/// with the ``HealthStatus/error`` status, and a Hub that cannot be
/// reached is one with the ``HealthStatus/warning`` status: an offline
/// machine with a warm cache still works.
public struct ProfileDoctor: Doctorable {
    // MARK: - Constants

    /// The group every finding of this component belongs to.
    public static let category = "profile"

    /// How long one resolver call may take, in seconds.
    ///
    /// A lookup asks a network endpoint, so it is never instant; and
    /// `doctor` must print its table even when the Hub stops answering.
    /// This is the bound both statements meet.
    public static let resolveTimeoutSeconds = 5.0

    /// The memory a machine must have for the shipped profile, in bytes:
    /// 32 GB (cli-plan.md §7).
    ///
    /// **The figure is the plan's, and this component does no arithmetic
    /// of its own.** Router's `JointFit` prices the three slots together
    /// against one shared budget, and it needs the repository metadata of
    /// each candidate to do it. This check reads no such metadata, so it
    /// compares the machine with the floor the plan measured for the
    /// shipped trio, and it applies that same floor to a profile that
    /// names other models.
    public static let memoryFloorBytes: Int64 = 34_359_738_368

    /// The bytes of one gigabyte, as every figure of this component is
    /// stated.
    private static let bytesPerGigabyte = 1_073_741_824.0

    /// How a figure in gigabytes is written.
    private static let gigabyteFormat = "%.1f GB"

    /// The separator between the owner and the name of a well formed
    /// reference.
    private static let ownerSeparator: Character = "/"

    /// The separator between a reference and the revision it pins, which
    /// the shape check takes off before it reads the owner and the name.
    private static let revisionSeparator: Character = "@"

    /// The number of parts a well formed reference has: the owner and the
    /// name.
    private static let wellFormedPartCount = 2

    /// The mark of a repository that carries an MTP draft head.
    private static let mtpMark = "-MTP-"

    /// The command a fix tells a person to run. It mirrors the `config
    /// edit` subcommand of the CLI, which this module cannot name.
    private static let editCommand = "acp-agent config edit"

    /// The check that states the memory of the machine.
    private static let memoryCheckName = "the profile memory floor"

    /// The check that states the free disk.
    private static let diskCheckName = "the free disk"

    /// The dotted key path of the profile section.
    private static let profileKey = AgentConfiguration.CodingKeys.profile.stringValue

    /// The dotted key path of the standard slot.
    private static let standardKey = key(ofSlot: .standard)

    /// The dotted key path of the flash slot.
    private static let flashKey = key(ofSlot: .flash)

    /// The dotted key path of the embedding slot.
    private static let embeddingKey = key(ofSlot: .embedding)

    /// The dotted key path of one slot.
    ///
    /// - Parameter slot: The slot to name.
    /// - Returns: The dotted key path.
    private static func key(ofSlot slot: ProfileConfiguration.CodingKeys) -> String {
        profileKey + LoadedConfiguration.keyPathSeparator + slot.stringValue
    }

    // MARK: - Stored state

    /// The resolved configuration, whose `profile:` section names the
    /// three slots.
    private let configuration: AgentConfiguration

    /// How the checks reach the Hub and the model cache.
    private let resolver: any ModelResolver

    /// The memory of the machine, in bytes.
    private let memoryBytes: Int64

    /// The free disk of the model cache, in bytes.
    private let freeDiskBytes: Int64

    /// How long one resolver call may take, in seconds.
    public let timeoutSeconds: Double

    // MARK: - Doctorable

    /// What this component is called in the doctor report.
    public let doctorName = ProfileDoctor.category

    /// The group its findings belong to.
    public let doctorCategory = ProfileDoctor.category

    /// Makes the component over one configuration, one resolver and the
    /// two machine figures.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration.
    ///   - resolver: How the checks reach the Hub and the cache.
    ///   - memoryBytes: The memory of the machine, in bytes.
    ///   - freeDiskBytes: The free disk of the model cache, in bytes.
    ///   - timeoutSeconds: How long one resolver call may take. The
    ///     default is ``resolveTimeoutSeconds``.
    public init(
        configuration: AgentConfiguration, resolver: any ModelResolver, memoryBytes: Int64,
        freeDiskBytes: Int64, timeoutSeconds: Double = ProfileDoctor.resolveTimeoutSeconds
    ) {
        self.configuration = configuration
        self.resolver = resolver
        self.memoryBytes = memoryBytes
        self.freeDiskBytes = freeDiskBytes
        self.timeoutSeconds = timeoutSeconds
    }

    /// Reports the rows of each slot reference, in slot order, and then
    /// the memory row and the disk row.
    ///
    /// - Returns: The findings, in that order.
    public func runHealthChecks() async -> [HealthCheck] {
        let references = slotReferences
        let lookups = await lookUps(of: references)
        let rows = references.enumerated().flatMap { position, entry in
            Self.checks(of: entry, lookup: lookups[position])
        }
        return rows + [memoryCheck, diskCheck(lookups: lookups)]
    }

    // MARK: - The slots

    /// One model reference, and the slot that names it.
    private struct SlotReference {
        /// The dotted key path of the slot.
        let key: String

        /// The reference the slot names.
        let reference: ModelRef
    }

    /// Every reference of every slot, in slot order and then in preference
    /// order.
    private var slotReferences: [SlotReference] {
        let slots = [
            (Self.standardKey, configuration.profile.standard),
            (Self.flashKey, configuration.profile.flash),
            (Self.embeddingKey, configuration.profile.embedding),
        ]
        return slots.flatMap { key, references in
            references.map { SlotReference(key: key, reference: $0) }
        }
    }

    // MARK: - The lookups

    /// The lookup of each well formed reference, by its position in
    /// `references`.
    ///
    /// A malformed reference is never looked up: the shape check has
    /// already refused it, and the Hub would only refuse it a second time.
    ///
    /// The references are looked up together, so one slow repository does
    /// not add its wait to the next one.
    ///
    /// - Parameter references: The references of every slot.
    /// - Returns: The lookups, by position.
    private func lookUps(of references: [SlotReference]) async -> [Int: ModelLookup] {
        await withTaskGroup(of: (Int, ModelLookup).self) { group in
            for (position, entry) in references.enumerated()
            where Self.isWellFormed(entry.reference) {
                group.addTask { (position, await self.lookUp(entry.reference)) }
            }
            var byPosition: [Int: ModelLookup] = [:]
            for await (position, lookup) in group {
                byPosition[position] = lookup
            }
            return byPosition
        }
    }

    /// Looks up one reference under ``timeoutSeconds``.
    ///
    /// - Parameter reference: The reference to look up.
    /// - Returns: What the lookup gave, or ``ModelLookup/noAnswer``.
    private func lookUp(_ reference: ModelRef) async -> ModelLookup {
        await ProbeTimeout.run(seconds: timeoutSeconds, timedOut: .noAnswer) {
            await resolver.lookUp(reference)
        }
    }

    // MARK: - The rows of one reference

    /// The rows of one slot reference: its shape, and — when the shape
    /// passes — its resolution, its cache state and its MTP head.
    ///
    /// - Parameters:
    ///   - entry: The reference and the slot that names it.
    ///   - lookup: What the lookup of that reference gave, or `nil` when
    ///     the shape check refused it.
    /// - Returns: The rows of that reference.
    private static func checks(
        of entry: SlotReference, lookup: ModelLookup?
    ) -> [HealthCheck] {
        let text = entry.reference.stringValue
        guard isWellFormed(entry.reference) else {
            return [shapeFailure(of: entry, text: text)]
        }
        return [shapePass(of: entry, text: text)]
            + resolveChecks(of: entry, text: text, lookup: lookup)
            + mtpChecks(of: entry, text: text)
    }

    // MARK: - The shape

    /// Whether one reference is `owner/name`, with no empty part and no
    /// white space.
    ///
    /// A pinned revision is taken off first: `owner/name@rev` is well
    /// formed, and the revision is the Hub's business and not this
    /// check's.
    ///
    /// - Parameter reference: The reference to test.
    /// - Returns: `true` when the reference is well formed.
    private static func isWellFormed(_ reference: ModelRef) -> Bool {
        let text = reference.stringValue
        guard !text.contains(where: \.isWhitespace) else {
            return false
        }
        let repo = text.prefix { $0 != revisionSeparator }
        let parts = repo.split(separator: ownerSeparator, omittingEmptySubsequences: false)
        return parts.count == wellFormedPartCount && parts.allSatisfy { !$0.isEmpty }
    }

    /// The row of a reference whose shape passes.
    ///
    /// - Parameters:
    ///   - entry: The reference and the slot that names it.
    ///   - text: The reference as a person reads it.
    /// - Returns: The row.
    private static func shapePass(of entry: SlotReference, text: String) -> HealthCheck {
        .ok(
            name: "\(entry.key): the shape of \(text)",
            message: "\(text) is a well formed owner/name reference", category: category)
    }

    /// The row of a reference whose shape does not pass.
    ///
    /// - Parameters:
    ///   - entry: The reference and the slot that names it.
    ///   - text: The reference as a person reads it.
    /// - Returns: The row.
    private static func shapeFailure(of entry: SlotReference, text: String) -> HealthCheck {
        .error(
            name: "\(entry.key): the shape of \(text)",
            message: "\(text) is not a well formed owner/name reference",
            fix: "set \(entry.key) in \(ConfigurationLoader.configFileName) to an "
                + "owner/name reference, with \(editCommand)",
            category: category)
    }

    // MARK: - The resolution and the cache state

    /// The resolve row of one reference, and its cache row when the Hub
    /// found it.
    ///
    /// - Parameters:
    ///   - entry: The reference and the slot that names it.
    ///   - text: The reference as a person reads it.
    ///   - lookup: What the lookup gave. It is `nil` only when no task was
    ///     started for this reference, which the shape check has already
    ///     reported.
    /// - Returns: The rows.
    private static func resolveChecks(
        of entry: SlotReference, text: String, lookup: ModelLookup?
    ) -> [HealthCheck] {
        let name = "\(entry.key): \(text) at Hugging Face"
        switch lookup {
        case .found(let downloadBytes):
            return [
                .ok(name: name, message: "\(text) is at Hugging Face", category: category),
                cacheCheck(of: entry, text: text, downloadBytes: downloadBytes),
            ]
        case .notFound:
            return [
                .error(
                    name: name, message: "Hugging Face has no repository \(text)",
                    fix: "correct \(entry.key) in \(ConfigurationLoader.configFileName), "
                        + "with \(editCommand)",
                    category: category)
            ]
        case .unreachable(let reason):
            return [
                .warning(
                    name: name,
                    message: "Hugging Face could not be reached for \(text): \(reason)",
                    fix: offlineFix, category: category)
            ]
        case .noAnswer, .none:
            return [
                .warning(
                    name: name,
                    message: "\(text) did not answer in \(resolveTimeoutSeconds) seconds",
                    fix: offlineFix, category: category)
            ]
        }
    }

    /// The fix of a Hub that did not answer: the network is what a person
    /// controls, and a model already in the cache still loads.
    private static let offlineFix =
        "connect this machine to the network and run doctor again; a model that is "
        + "already in the model cache still loads offline"

    /// The cache row of one reference: whether the next run downloads.
    ///
    /// - Parameters:
    ///   - entry: The reference and the slot that names it.
    ///   - text: The reference as a person reads it.
    ///   - downloadBytes: What the next run must still download.
    /// - Returns: The row.
    private static func cacheCheck(
        of entry: SlotReference, text: String, downloadBytes: Int64
    ) -> HealthCheck {
        let name = "\(entry.key): \(text) on disk"
        guard downloadBytes > 0 else {
            return .ok(
                name: name,
                message: "\(text) is already in the model cache, so the next run "
                    + "downloads nothing", category: category)
        }
        return .ok(
            name: name,
            message: "\(text) is not in the model cache, so the next run downloads "
                + gigabytes(downloadBytes), category: category)
    }

    // MARK: - The MTP head

    /// The MTP row of one reference, and no row at all when the reference
    /// names no MTP build.
    ///
    /// Router calls the plain generate path and never reads the MTP head,
    /// so the download is larger and the speed is the same (cli-plan.md
    /// §7.1).
    ///
    /// - Parameters:
    ///   - entry: The reference and the slot that names it.
    ///   - text: The reference as a person reads it.
    /// - Returns: The one row, or no row.
    private static func mtpChecks(of entry: SlotReference, text: String) -> [HealthCheck] {
        guard text.contains(mtpMark) else {
            return []
        }
        return [
            .warning(
                name: "\(entry.key): the MTP head of \(text)",
                message: "\(text) is an MTP build, and Router calls the plain generate "
                    + "path, so the download is larger and the speed is the same",
                fix: "set \(entry.key) in \(ConfigurationLoader.configFileName) to a "
                    + "build with no MTP head, with \(editCommand)",
                category: category)
        ]
    }

    // MARK: - The memory fit

    /// The row of the memory of the machine against
    /// ``memoryFloorBytes``.
    private var memoryCheck: HealthCheck {
        let message =
            "this machine has \(Self.gigabytes(memoryBytes)), and the profile needs "
            + Self.gigabytes(Self.memoryFloorBytes)
        guard memoryBytes < Self.memoryFloorBytes else {
            return .ok(name: Self.memoryCheckName, message: message, category: Self.category)
        }
        return .error(
            name: Self.memoryCheckName, message: message, fix: Self.smallerProfileFix,
            category: Self.category)
    }

    /// The fix of a machine below the floor: name a smaller model in the
    /// standard slot. The `flash` default is the smaller model this
    /// package already ships, and it fits a 16 GB machine.
    private static let smallerProfileFix =
        "set \(standardKey) in \(ConfigurationLoader.configFileName) to a smaller model, "
        + "such as \(describe(ProfileConfiguration.defaultFlash)), with \(editCommand)"

    // MARK: - The free disk

    /// The row of the free disk against what the next run must still
    /// download.
    ///
    /// - Parameter lookups: What every lookup gave, by position.
    /// - Returns: The row.
    private func diskCheck(lookups: [Int: ModelLookup]) -> HealthCheck {
        let needed = Self.downloadBytes(of: lookups)
        guard needed > 0 else {
            return .ok(
                name: Self.diskCheckName,
                message: "every model is in the model cache, so the next run downloads "
                    + "nothing", category: Self.category)
        }
        let message =
            "the next run downloads \(Self.gigabytes(needed)), and "
            + "\(Self.gigabytes(freeDiskBytes)) is free"
        guard needed > freeDiskBytes else {
            return .ok(name: Self.diskCheckName, message: message, category: Self.category)
        }
        return .error(
            name: Self.diskCheckName, message: message, fix: Self.diskFix,
            category: Self.category)
    }

    /// What every found reference must still download, in bytes.
    ///
    /// - Parameter lookups: What every lookup gave, by position.
    /// - Returns: The bytes.
    private static func downloadBytes(of lookups: [Int: ModelLookup]) -> Int64 {
        lookups.values.reduce(0) { total, lookup in
            guard case .found(let downloadBytes) = lookup else {
                return total
            }
            return total + downloadBytes
        }
    }

    /// The fix of a volume that is too small: make space, or name smaller
    /// models.
    private static let diskFix =
        "make space on the volume of the model cache, or set \(profileKey) in "
        + "\(ConfigurationLoader.configFileName) to smaller models, with \(editCommand)"

    // MARK: - The shared shapes

    /// One figure of bytes as a person reads it, in gigabytes.
    ///
    /// - Parameter bytes: The figure to write.
    /// - Returns: The text.
    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: gigabyteFormat, Double(bytes) / bytesPerGigabyte)
    }

    /// One candidate list as a person reads it.
    ///
    /// - Parameter references: The references to write.
    /// - Returns: The text.
    private static func describe(_ references: [ModelRef]) -> String {
        references.map(\.stringValue).joined(separator: ", ")
    }
}
