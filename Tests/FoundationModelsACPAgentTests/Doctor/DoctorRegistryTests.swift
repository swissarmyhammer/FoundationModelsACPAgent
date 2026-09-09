import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// The doctor component registry of `acp-agent` (cli-plan.md §5.12): the
/// two components this card writes, and the fix rule that holds over every
/// finding they report.
struct DoctorRegistryTests {
    // MARK: - Constants

    /// A top-level section no schema section is named after, which makes
    /// the configuration component warn.
    private static let unknownSectionName = "surprise"

    /// The number of components this card registers.
    private static let registeredComponentCount = 2

    // MARK: - Helpers

    /// The registered components over `fixture`'s stack.
    ///
    /// - Parameter fixture: The two-layer tree the components read.
    /// - Returns: The components, in registration order.
    private static func components(in fixture: ConfigCommandFixture) -> [any Doctorable] {
        AcpAgentCommand.Doctor.components(
            workingDirectory: fixture.workspace, environment: fixture.environment)
    }

    // MARK: - The registry

    /// The registry states the configuration component and the transcripts
    /// component, in that order.
    @Test func theRegistryStatesTheConfigurationAndTheTranscriptsComponents() {
        let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-registry")

        let components = Self.components(in: fixture)

        #expect(components.count == Self.registeredComponentCount)
        #expect(
            components.map(\.doctorCategory) == [
                ConfigurationDoctor.category, TranscriptsDoctor.category,
            ])
    }

    // MARK: - The fix rule

    /// Every finding these components report that is not `ok` carries a
    /// fix: a person who reads a warning or a failure is told what to do
    /// about it.
    @Test func noWarningOrErrorCarriesANilFix() async throws {
        let fixture = ConfigCommandFixture(label: "DoctorRegistryTests-fixes")
        try fixture.writeProjectConfig("\(Self.unknownSectionName):\n  key: yes\n")

        let report = await DoctorRunner(components: Self.components(in: fixture)).run()

        #expect(report.checks.contains { $0.status == .warning })
        #expect(report.checks.allSatisfy { $0.status == .ok || $0.fix != nil })
    }
}
