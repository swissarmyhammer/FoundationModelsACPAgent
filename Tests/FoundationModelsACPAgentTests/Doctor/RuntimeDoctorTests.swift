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

    /// The start of the name of each row of the skills tool.
    private static let skillsRowPrefix = "the skills"

    /// The start of the name of each row of the agents tool.
    private static let agentsRowPrefix = "the agents"

    /// The dotfolder name of the configuration of the settings folders. The
    /// skills and agents stacks do not read it.
    private static let dotfolderName = "runtime-doctor-test"

    // MARK: - Helpers

    /// The component over one fixture tree.
    ///
    /// - Parameters:
    ///   - fixture: The two-layer tree the skills stack roots in.
    ///   - rootSettingsFolder: The root settings folder of the host, or
    ///     `nil` (the default) for the XDG layers of the CLI.
    /// - Returns: The component.
    /// - Throws: `DotfolderNameError` when the dotfolder name is refused.
    private static func doctor(
        in fixture: ConfigCommandFixture, rootSettingsFolder: URL? = nil
    ) throws -> RuntimeDoctor {
        RuntimeDoctor(
            workingDirectory: fixture.workspace,
            settingsFolders: SettingsFolders(
                name: try DotfolderName(dotfolderName), rootSettingsFolder: rootSettingsFolder,
                environment: fixture.environment))
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
    @Test func aStackWithNoLayerOnDiskPasses() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-absent")

        let checks = try await Self.doctor(in: fixture).runHealthChecks()

        #expect(!checks.isEmpty)
        #expect(checks.allSatisfy { $0.status == .ok })
    }

    /// A skills layer that is on disk and can be read passes, and its row
    /// names the directory.
    @Test func aReadableLayerPassesAndNamesTheDirectory() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-readable")
        let layer = Self.projectSkillsDirectory(of: fixture)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)

        let checks = try await Self.doctor(in: fixture).runHealthChecks()

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

        let checks = try await Self.doctor(in: fixture).runHealthChecks()
        try setPermissions(ownerOnlyPermissions, of: layer)

        let errors = Self.findings(.error, in: checks)
        let failure = try #require(errors.first)
        let fix = try #require(failure.fix)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(layer.path))
        #expect(fix.contains(layer.path))
    }

    // MARK: - The agents tool

    /// The component gives one row for each layer of the agents stack, and
    /// a layer that is not on disk passes.
    @Test func theComponentGivesOneRowForEachAgentsLayer() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-agents")

        let checks = try await Self.doctor(in: fixture).runHealthChecks()

        let agentsChecks = checks.filter { $0.name.hasPrefix(Self.agentsRowPrefix) }
        #expect(!agentsChecks.isEmpty)
        #expect(agentsChecks.allSatisfy { $0.status == .ok })
    }

    // MARK: - The root settings folder

    /// With a root settings folder, the rows give the skills layer in the
    /// root, and no row gives a layer in the XDG config home.
    @Test func withARootTheRowsGiveTheLayersOfTheRoot() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-root")
        let root = makeResolvedDirectory(label: "RuntimeDoctorTests-root-settings")
        let skillsLayer = root.appendingPathComponent(SettingsFolders.skillsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: skillsLayer, withIntermediateDirectories: true)

        let checks = try await Self.doctor(in: fixture, rootSettingsFolder: root).runHealthChecks()

        #expect(checks.contains { $0.message.contains(skillsLayer.path) })
        #expect(!checks.contains { $0.message.contains(fixture.configHome.path) })
    }

    // MARK: - The tools that are always on

    /// The skills tool and the `agents` tool are always on. Each row of the
    /// component is a layer row of the skills stack or of the agents stack,
    /// and no row says that a tool is disabled.
    @Test func eachRowIsALayerRowAndNoRowSaysDisabled() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-always-on")

        let checks = try await Self.doctor(in: fixture).runHealthChecks()

        #expect(
            checks.allSatisfy {
                $0.name.hasPrefix(Self.skillsRowPrefix) || $0.name.hasPrefix(Self.agentsRowPrefix)
            })
        #expect(!checks.contains { $0.message.contains(DisabledSectionCheck.disabledWord) })
    }

    // MARK: - The fix rule

    /// Every finding this component reports that is not `ok` carries a fix,
    /// over a tree whose project layer cannot be read.
    @Test func noWarningOrErrorCarriesANilFix() async throws {
        let fixture = ConfigCommandFixture(label: "RuntimeDoctorTests-fixes")
        let layer = Self.projectSkillsDirectory(of: fixture)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        try setPermissions(Self.unreadablePermissions, of: layer)

        let checks = try await Self.doctor(in: fixture).runHealthChecks()
        try setPermissions(ownerOnlyPermissions, of: layer)

        #expect(checks.contains { $0.status != .ok })
        #expect(checks.allSatisfy { $0.status == .ok || $0.fix != nil })
    }
}
