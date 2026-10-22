import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// `HomeDoctor` (task ^98a44n7): `doctor` shows the resolved home, one row
/// for the synced root and one for the local root, and each row names its
/// folder.
struct HomeDoctorTests {
    // MARK: - Constants

    /// The number of rows of the component: the synced root and the local
    /// root.
    private static let rowCount = 2

    /// The number of findings a test that expects exactly one gets.
    private static let oneFinding = 1

    /// The name of a folder that is not on disk yet.
    private static let missingFolderName = "not-yet"

    /// The name of a file that blocks a root.
    private static let blockingFileName = "blocking-file"

    // MARK: - Tests

    /// A home over two folders on disk gives two passing rows, and each row
    /// names its folder.
    @Test func eachRootIsOneRowThatNamesItsFolder() async throws {
        let home = AgentHomeFixture.make(label: "HomeDoctorTests-rows")

        let checks = await HomeDoctor(home: home).runHealthChecks()

        #expect(checks.count == Self.rowCount)
        #expect(checks.allSatisfy { $0.status == .ok && $0.category == HomeDoctor.category })
        #expect(checks.contains { $0.message.contains(home.synced.standardizedFileURL.path) })
        #expect(checks.contains { $0.message.contains(home.local.standardizedFileURL.path) })
    }

    /// A root that is not on disk yet passes, because the agent makes it
    /// when it first writes there.
    @Test func aRootThatIsNotOnDiskYetPasses() async {
        let folder = makeResolvedDirectory(label: "HomeDoctorTests-missing")
        let home = AgentHome.custom(
            synced: folder.appendingPathComponent(Self.missingFolderName, isDirectory: true),
            local: folder)

        let checks = await HomeDoctor(home: home).runHealthChecks()

        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks.contains { $0.message.contains(home.synced.standardizedFileURL.path) })
    }

    /// A root that a file blocks is one error that names the root and
    /// carries a fix.
    @Test func aRootThatAFileBlocksIsAnError() async throws {
        let folder = makeResolvedDirectory(label: "HomeDoctorTests-blocked")
        let file = folder.appendingPathComponent(Self.blockingFileName)
        try Data().write(to: file)
        let home = AgentHome.custom(synced: folder, local: file)

        let checks = await HomeDoctor(home: home).runHealthChecks()

        let errors = checks.filter { $0.status == .error }
        let failure = try #require(errors.first)
        #expect(errors.count == Self.oneFinding)
        #expect(failure.message.contains(file.standardizedFileURL.path))
        #expect(failure.fix != nil)
    }
}
