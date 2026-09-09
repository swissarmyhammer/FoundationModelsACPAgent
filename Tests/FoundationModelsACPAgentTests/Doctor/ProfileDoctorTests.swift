import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// `ProfileDoctor` (cli-plan.md §5.12, the Profile row): each model
/// reference is well formed, each one resolves, the cache state says
/// whether the next run downloads, the trio fits the memory of the
/// machine, the free disk covers the download, and an MTP slot warns.
///
/// Every test drives the component over a scripted ``StubModelResolver``
/// and over injected memory and disk figures, so no test asks Hugging
/// Face, no test reads the real model cache, and no finding depends on the
/// machine the suite runs on.
struct ProfileDoctorTests {
    // MARK: - Constants

    /// The number of findings a test that expects exactly one gets.
    private static let oneFinding = 1

    /// A memory figure far above the floor, so the memory row passes.
    private static let generousMemoryBytes: Int64 = 68_719_476_736

    /// A free-disk figure far above any download, so the disk row passes.
    private static let generousDiskBytes: Int64 = 1_099_511_627_776

    /// A memory figure below the floor: 16 GB, the machine cli-plan.md §7
    /// names as too small.
    private static let smallMemoryBytes: Int64 = 17_179_869_184

    /// How ``smallMemoryBytes`` is stated in a message.
    private static let smallMemoryText = "16.0 GB"

    /// How ``ProfileDoctor/memoryFloorBytes`` is stated in a message.
    private static let memoryFloorText = "32.0 GB"

    /// A free-disk figure below the download of the scripted trio.
    private static let smallDiskBytes: Int64 = 1_073_741_824

    /// The bytes one scripted reference must still download.
    private static let downloadBytes: Int64 = 10_737_418_240

    /// How ``smallDiskBytes`` is stated in a message.
    private static let smallDiskText = "1.0 GB"

    /// How the download of the three scripted references, each of
    /// ``downloadBytes``, is stated in a message.
    private static let wholeDownloadText = "30.0 GB"

    /// The words the message of a reference the cache already holds
    /// carries.
    private static let cachedWords = "already in the model cache"

    /// The words the message of a reference the cache does not hold
    /// carries.
    private static let absentWords = "not in the model cache"

    /// A reference with no owner part, which is malformed.
    private static let malformedReference: ModelRef = "Qwen3-4B-4bit"

    /// A reference that names an MTP build, whose draft head Router never
    /// reads (cli-plan.md §7.1).
    private static let mtpReference: ModelRef = "mlx-community/Qwen3.5-9B-MTP-4bit"

    /// The dotted key of the standard slot.
    private static let standardKey = "profile.standard"

    /// The dotted key of the flash slot.
    private static let flashKey = "profile.flash"

    /// The command a fix tells a person to run.
    private static let editCommand = "acp-agent config edit"

    /// The reason a scripted network failure gives.
    private static let unreachableReason = "the host could not be reached"

    /// The timeout a test that proves the timeout injects, in seconds. It
    /// is far below ``timeoutCeilingSeconds``, so the assertion on the
    /// elapsed time cannot pass by accident.
    private static let shortTimeoutSeconds = 0.2

    /// The bound the elapsed time of a run against a resolver that does
    /// not answer in time must stay under, in seconds.
    private static let timeoutCeilingSeconds = 2.0

    // MARK: - Helpers

    /// The component over one configuration, one resolver and the two
    /// machine figures.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration the checks read.
    ///   - resolver: The scripted resolver.
    ///   - memoryBytes: The memory of the machine, in bytes.
    ///   - freeDiskBytes: The free disk of the model cache, in bytes.
    ///   - timeoutSeconds: How long one lookup may take.
    /// - Returns: The component.
    private static func doctor(
        configuration: AgentConfiguration = AgentConfiguration(),
        resolver: StubModelResolver = StubModelResolver(),
        memoryBytes: Int64 = ProfileDoctorTests.generousMemoryBytes,
        freeDiskBytes: Int64 = ProfileDoctorTests.generousDiskBytes,
        timeoutSeconds: Double = ProfileDoctor.resolveTimeoutSeconds
    ) -> ProfileDoctor {
        ProfileDoctor(
            configuration: configuration, resolver: resolver, memoryBytes: memoryBytes,
            freeDiskBytes: freeDiskBytes, timeoutSeconds: timeoutSeconds)
    }

    /// The findings of `checks` that carry `status`.
    ///
    /// - Parameters:
    ///   - status: The status to keep.
    ///   - checks: The findings to filter.
    /// - Returns: The findings that carry `status`.
    private static func findings(
        _ status: HealthStatus, in checks: [HealthCheck]
    ) -> [HealthCheck] {
        checks.filter { $0.status == status }
    }

    /// A configuration whose `standard` slot names one reference.
    ///
    /// - Parameter reference: The reference the slot names.
    /// - Returns: The configuration.
    private static func configuration(standard reference: ModelRef) -> AgentConfiguration {
        var configuration = AgentConfiguration()
        configuration.profile.standard = [reference]
        return configuration
    }

    /// A lookup table that finds every reference of `references`, each one
    /// already in the cache.
    ///
    /// - Parameter references: The references the table names.
    /// - Returns: The table.
    private static func foundLookups(of references: [ModelRef]) -> [String: ModelLookup] {
        Dictionary(
            uniqueKeysWithValues: references.map {
                ($0.stringValue, ModelLookup.found(downloadBytes: 0))
            })
    }

    // MARK: - The shipped defaults

    /// The shipped defaults, an all-found resolver and generous figures
    /// give rows and every one of them passes. The fixture decides the
    /// answer, so the result is the same on any machine.
    @Test func theShippedDefaultsWithAGenerousFixtureGiveOnlyPassingRows() async {
        let checks = await Self.doctor().runHealthChecks()

        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.status == .ok })
    }

    // MARK: - The shape check

    /// A reference with no owner part is one `.error` that names the slot
    /// and the reference.
    @Test func aMalformedReferenceGivesOneErrorThatNamesTheSlot() async throws {
        let checks = await Self.doctor(
            configuration: Self.configuration(standard: Self.malformedReference)
        ).runHealthChecks()

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.name.contains(Self.standardKey))
        #expect(failure.message.contains(Self.malformedReference.stringValue))
        #expect(failure.fix != nil)
    }

    /// A malformed reference is never looked up: the shape check comes
    /// first, so the resolver that refuses every reference it does not
    /// know adds no second failure for it.
    @Test func aMalformedReferenceIsNeverLookedUp() async {
        let resolver = StubModelResolver(
            namedLookups: Self.foundLookups(
                of: ProfileConfiguration.defaultFlash + ProfileConfiguration.defaultEmbedding),
            lookup: .notFound)

        let checks = await Self.doctor(
            configuration: Self.configuration(standard: Self.malformedReference),
            resolver: resolver
        ).runHealthChecks()

        #expect(Self.findings(.error, in: checks).count == Self.oneFinding)
    }

    // MARK: - The resolve check

    /// A reference the resolver does not find is one `.error` that names
    /// the slot and the reference, and whose fix names `config edit`.
    @Test func aReferenceThatIsNotFoundGivesOneErrorWithTheEditFix() async throws {
        let reference = ProfileConfiguration.defaultStandard[0]
        let resolver = StubModelResolver(namedLookups: [reference.stringValue: .notFound])

        let checks = await Self.doctor(resolver: resolver).runHealthChecks()

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.name.contains(Self.standardKey))
        #expect(failure.message.contains(reference.stringValue))
        #expect(fix.contains(Self.editCommand))
    }

    /// A network failure is one `.warning` and no `.error`: an offline
    /// machine with a warm cache still works.
    @Test func aNetworkFailureGivesOneWarningAndNoError() async throws {
        let reference = ProfileConfiguration.defaultStandard[0]
        let resolver = StubModelResolver(
            namedLookups: [
                reference.stringValue: .unreachable(reason: Self.unreachableReason)
            ])

        let checks = await Self.doctor(resolver: resolver).runHealthChecks()

        let warnings = Self.findings(.warning, in: checks)
        let warning = try #require(warnings.first)
        #expect(warnings.count == Self.oneFinding)
        #expect(warning.message.contains(Self.unreachableReason))
        #expect(warning.fix != nil)
        #expect(Self.findings(.error, in: checks).isEmpty)
    }

    /// A resolver that does not answer in time gives one `.warning`, and
    /// the run ends inside the named timeout instead of hanging.
    @Test func aResolverThatDoesNotAnswerInTimeWarnsInsideTheNamedTimeout() async throws {
        let reference = ProfileConfiguration.defaultStandard[0]
        let resolver = StubModelResolver(silentReferences: [reference.stringValue])
        let start = ContinuousClock.now

        let checks = await Self.doctor(
            resolver: resolver, timeoutSeconds: Self.shortTimeoutSeconds
        ).runHealthChecks()
        let elapsed = ContinuousClock.now - start

        let warnings = Self.findings(.warning, in: checks)
        let warning = try #require(warnings.first)
        #expect(elapsed < .seconds(Self.timeoutCeilingSeconds))
        #expect(warnings.count == Self.oneFinding)
        #expect(warning.message.contains(reference.stringValue))
        #expect(warning.fix != nil)
    }

    /// The component takes ``ProfileDoctor/resolveTimeoutSeconds`` when
    /// the caller states no timeout, so the production run carries the
    /// named bound.
    @Test func theDefaultTimeoutIsTheNamedResolveTimeout() {
        let component = ProfileDoctor(
            configuration: AgentConfiguration(), resolver: StubModelResolver(),
            memoryBytes: Self.generousMemoryBytes, freeDiskBytes: Self.generousDiskBytes)

        #expect(component.timeoutSeconds == ProfileDoctor.resolveTimeoutSeconds)
    }

    // MARK: - The cache state

    /// A reference the cache already holds says so, so a person knows the
    /// next run downloads nothing.
    @Test func aCachedReferenceSaysTheNextRunDownloadsNothing() async {
        let checks = await Self.doctor().runHealthChecks()

        #expect(checks.contains { $0.message.contains(Self.cachedWords) })
    }

    /// A reference the cache does not hold says how much the next run
    /// downloads, and it is still a passing row.
    @Test func anAbsentReferenceStatesWhatTheNextRunDownloads() async throws {
        let resolver = StubModelResolver(lookup: .found(downloadBytes: Self.downloadBytes))

        let checks = await Self.doctor(resolver: resolver).runHealthChecks()

        let note = try #require(
            checks.first { $0.message.contains(Self.absentWords) })
        #expect(note.status == .ok)
    }

    // MARK: - The memory fit

    /// A memory figure below the floor is one `.error` that states both
    /// figures, and whose fix names a smaller model.
    @Test func aMemoryFigureBelowTheFloorGivesOneErrorWithBothFigures() async throws {
        let checks = await Self.doctor(memoryBytes: Self.smallMemoryBytes).runHealthChecks()

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(Self.smallMemoryText))
        #expect(failure.message.contains(Self.memoryFloorText))
        #expect(fix.contains(Self.standardKey))
    }

    // MARK: - The free disk

    /// A free-disk figure below what must still be downloaded is one
    /// `.error` that states both figures.
    @Test func aFreeDiskFigureBelowTheDownloadGivesOneError() async throws {
        let resolver = StubModelResolver(lookup: .found(downloadBytes: Self.downloadBytes))

        let checks = await Self.doctor(
            resolver: resolver, freeDiskBytes: Self.smallDiskBytes
        ).runHealthChecks()

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(Self.smallDiskText))
        #expect(failure.message.contains(Self.wholeDownloadText))
        #expect(failure.fix != nil)
    }

    // MARK: - The MTP warning

    /// A slot that names an MTP build is exactly one `.warning`, because
    /// Router never reads the MTP head (cli-plan.md §7.1).
    @Test func anMTPSlotGivesExactlyOneWarning() async throws {
        var configuration = AgentConfiguration()
        configuration.profile.flash = [Self.mtpReference]

        let checks = await Self.doctor(configuration: configuration).runHealthChecks()

        let warnings = Self.findings(.warning, in: checks)
        let warning = try #require(warnings.first)
        #expect(warnings.count == Self.oneFinding)
        #expect(warning.name.contains(Self.flashKey))
        #expect(warning.message.contains(Self.mtpReference.stringValue))
        #expect(warning.fix != nil)
    }

    /// The shipped defaults name no MTP build, so they give no MTP
    /// warning.
    @Test func theShippedDefaultsGiveNoMTPWarning() async {
        let checks = await Self.doctor().runHealthChecks()

        #expect(Self.findings(.warning, in: checks).isEmpty)
    }

    // MARK: - The fix rule

    /// Every finding this component reports that is not `ok` carries a
    /// fix, over a profile that makes the shape, the resolution, the MTP
    /// head, the memory and the disk all report a fault at once.
    @Test func noWarningOrErrorCarriesANilFix() async {
        var configuration = Self.configuration(standard: Self.malformedReference)
        configuration.profile.flash = [Self.mtpReference]
        let resolver = StubModelResolver(
            namedLookups: [Self.mtpReference.stringValue: .notFound],
            lookup: .found(downloadBytes: Self.downloadBytes))

        let checks = await Self.doctor(
            configuration: configuration, resolver: resolver,
            memoryBytes: Self.smallMemoryBytes, freeDiskBytes: Self.smallDiskBytes
        ).runHealthChecks()

        #expect(checks.contains { $0.status != .ok })
        #expect(checks.allSatisfy { $0.status == .ok || $0.fix != nil })
    }
}
