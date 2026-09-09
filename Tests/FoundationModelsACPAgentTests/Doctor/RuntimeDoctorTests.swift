import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// `RuntimeDoctor` (cli-plan.md §5.12, the Skills row): the skills
/// dotfolder stack is found, and every layer of it that is on disk can be
/// read.
///
/// Each test drives the component over a throwaway two-layer tree, so no
/// test reads the real home directory and the findings are the same on any
/// machine.
struct RuntimeDoctorTests {
    // MARK: - Constants

    /// The number of findings a test that expects exactly one gets.
    private static let oneFinding = 1

    /// The permissions of a directory that can be entered and written but
    /// not read, which is how a test makes a layer unreadable.
    private static let unreadablePermissions = NSNumber(value: 0o300)

    /// The word a disabled tool section reports, so a person sees why the
    /// tool is absent.
    private static let disabledWord = "disabled"

    /// The configuration key a disabled-section row names.
    private static let skillsKey = "tools.skills"

    // MARK: - Helpers

    /// The component over one configuration and one fixture tree.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration the checks read.
    ///   - fixture: The two-layer tree the skills stack roots in.
    /// - Returns: The component.
    private static func doctor(
        configuration: AgentConfiguration = AgentConfiguration(),
        in fixture: ConfigCommandFixture
    ) -> RuntimeDoctor {
        RuntimeDoctor(
            configuration: configuration, workingDirectory: fixture.workspace,
            environment: fixture.environment)
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

    /// The project skills layer of `fixture`, `<workspace>/.skills`.
    ///
    /// - Parameter fixture: The tree the layer roots in.
    /// - Returns: The layer root.
    private static func projectSkillsDirectory(of fixture: ConfigCommandFixture) -> URL {
        fixture.workspace.appendingPathComponent(
            ".\(ToolCatalog.skillsDotfolderName)", isDirectory: true)
    }

    // MARK: - The skills stack

    /// A tree with no skills layer on disk passes. Skills are optional, so
    /// a fresh install that never made one is not a fault.
    @Test func aStackWithNoLayerOnDiskPasses() async {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-absent")

        let checks = await Self.doctor(in: fixture).runHealthChecks()

        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.status == .ok })
    }

    /// A skills layer that is on disk and can be read passes, and its row
    /// names the directory.
    @Test func aReadableLayerPassesAndNamesTheDirectory() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-readable")
        let layer = Self.projectSkillsDirectory(of: fixture)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)

        let checks = await Self.doctor(in: fixture).runHealthChecks()

        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks.contains { $0.message.contains(layer.path) })
    }

    /// A skills layer that is on disk but cannot be read is one `.error`
    /// that names the directory and carries a fix.
    @Test func anUnreadableLayerGivesOneErrorThatNamesTheDirectory() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-unreadable")
        let layer = Self.projectSkillsDirectory(of: fixture)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        try setPermissions(Self.unreadablePermissions, of: layer)

        let checks = await Self.doctor(in: fixture).runHealthChecks()
        try setPermissions(ownerOnlyPermissions, of: layer)

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(layer.path))
        #expect(fix.contains(layer.path))
    }

    // MARK: - The disabled section

    /// `tools.skills: false` gives one `.ok` row that says disabled, and no
    /// layer is read: a layer that cannot be read changes nothing.
    @Test func aDisabledSkillsSectionSaysDisabledAndReadsNoLayer() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-off")
        let layer = Self.projectSkillsDirectory(of: fixture)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        try setPermissions(Self.unreadablePermissions, of: layer)
        var configuration = AgentConfiguration()
        configuration.tools.skills = .disabled

        let checks = await Self.doctor(configuration: configuration, in: fixture)
            .runHealthChecks()
        try setPermissions(ownerOnlyPermissions, of: layer)

        #expect(checks.count == Self.oneFinding)
        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks.contains { $0.message.contains(Self.disabledWord) })
        #expect(checks.contains { $0.message.contains(Self.skillsKey) })
    }

    // MARK: - The fix rule

    /// Every finding this component reports that is not `ok` carries a fix,
    /// over a tree whose project layer cannot be read.
    @Test func noWarningOrErrorCarriesANilFix() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-fixes")
        let layer = Self.projectSkillsDirectory(of: fixture)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        try setPermissions(Self.unreadablePermissions, of: layer)

        let checks = await Self.doctor(in: fixture).runHealthChecks()
        try setPermissions(ownerOnlyPermissions, of: layer)

        #expect(checks.contains { $0.status != .ok })
        #expect(checks.allSatisfy { $0.status == .ok || $0.fix != nil })
    }
}
