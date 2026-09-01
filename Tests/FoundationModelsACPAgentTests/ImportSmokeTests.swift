import FoundationModelsACP
import FoundationModelsACPAgent
import FoundationModelsACPClient
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import FoundationModelsSkills
import Testing

/// The smoke test for the package linkage (plan.md §1).
///
/// The test imports each of the five family modules that the library target
/// declares, and the client module that the test target alone declares. It
/// names one public type from each module and asserts the type's name. When
/// this file compiles and the tests pass, each dependency in `Package.swift`
/// is real and not declared prose.
@Suite struct ImportSmokeTests {
    /// The wire: the ACP `Agent` role protocol that `RoutedACPAgent` adopts.
    @Test func wireLinksTheAgentProtocol() {
        #expect(String(describing: (any Agent).self) == "Agent")
    }

    /// The runtime: `Router` resolves a profile to a resident model.
    @Test func runtimeLinksTheRouter() {
        #expect(String(describing: Router.self) == "Router")
    }

    /// The dotfolder stack: `DotfolderStack` is the configuration substrate.
    @Test func extrasLinksTheDotfolderStack() {
        #expect(String(describing: DotfolderStack.self) == "DotfolderStack")
    }

    /// The consolidated tool surface: `MultiTool.Builder` composes the
    /// capability modules behind one `runCode` tool.
    @Test func multitoolLinksTheBuilder() {
        #expect(String(describing: MultiTool.Builder.self) == "Builder")
    }

    /// The stand-alone skills package: `SkillsRegistry` is its catalog.
    @Test func skillsLinksTheRegistry() {
        #expect(String(describing: SkillsRegistry.self) == "SkillsRegistry")
    }

    /// The client driver (plan.md §20.1): the test target links
    /// `FoundationModelsACPClient`, and the library target never does.
    @Test func testTargetLinksTheClientDriver() {
        #expect(String(describing: SwiftUIACPClient.self) == "SwiftUIACPClient")
    }

    /// This package: the placeholder namespace the library target exports.
    @Test func libraryExportsItsNamespace() {
        #expect(String(describing: RoutedACPAgentPackage.self) == "RoutedACPAgentPackage")
    }
}
