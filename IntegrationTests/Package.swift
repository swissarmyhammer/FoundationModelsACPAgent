// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The root package this one tests, reached by path.
private let rootPackageName = "FoundationModelsACPAgent"

/// The name of this package and of its one test target.
private let integrationTargetName = "\(rootPackageName)IntegrationTests"

/// The root package's shared test-support product (plan.md §20.1): the
/// in-process harness, the scripted model, the stub profile fixtures, the
/// built-product locator, and the assertion helpers. The root unit target
/// links the same product, so the two sides cannot drift apart.
private let testSupportProductName = "\(rootPackageName)TestSupport"

/// The agent CLI executable of the root package (cli-plan.md §2). It is a
/// product dependency, so SwiftPM builds the binary into the products
/// directory beside this test bundle, where `BuiltProductLocator` finds it
/// and `StdioContractTests` spawns it in `acp` mode.
private let agentExecutableName = "acp-agent"

/// The one-shot client CLI of the root package (plan.md §20.2), declared
/// for the same reason as `agentExecutableName`: `ClientServerTests` runs
/// the built binary.
private let printExecutableName = "acp-print"

/// The base URL of the packages under the swissarmyhammer GitHub
/// organization, as the root manifest declares them.
private let swissArmyHammerOrgURL = "git@github.com:swissarmyhammer/"

/// The branch each family sibling is tracked on, as the root manifest
/// declares it.
private let mainBranch = "main"

/// The ACP wire (plan.md §1). The suites here assert on wire types.
private let wireDependencyName = "FoundationModelsACP"

/// The Client role (plan.md §20.1): the driver of every test level above
/// the unit level.
private let clientDependencyName = "FoundationModelsACPClient"

/// The one-shot client CLI of the client package (its cli-plan.md §6). It
/// is a product dependency for the reason `agentExecutableName` is: SwiftPM
/// builds the binary into the products directory beside this test bundle,
/// where `BuiltProductLocator` finds it and `ClientInteropTests` runs it
/// against the agent binary standing next to it.
private let clientExecutableName = "acp-client"

/// SwiftPM manifest for the integration suites of FoundationModelsACPAgent.
///
/// This package exists so that `swift test` at the repository root runs the
/// unit suites and only the unit suites, as the org test contract asks. The
/// suites here spawn built binaries across a real process boundary, so they
/// run through `swift test --package-path IntegrationTests` and through the
/// shared CI workflow's integration job. No environment variable selects
/// them.
///
/// Every suite here is deterministic and a failure is a defect. Nothing
/// here loads a model. The evaluations, which do load a real model and
/// which score rather than assert, are the `EvaluationTests` package, and
/// CI never runs them. See that manifest for why the two are apart.
let package = Package(
    name: integrationTargetName,
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "\(swissArmyHammerOrgURL)\(wireDependencyName).git", branch: mainBranch),
        .package(url: "\(swissArmyHammerOrgURL)\(clientDependencyName).git", branch: mainBranch),
    ],
    targets: [
        .testTarget(
            name: integrationTargetName,
            dependencies: [
                .product(name: rootPackageName, package: rootPackageName),
                .product(name: testSupportProductName, package: rootPackageName),
                .product(name: agentExecutableName, package: rootPackageName),
                .product(name: printExecutableName, package: rootPackageName),
                .product(name: wireDependencyName, package: wireDependencyName),
                .product(name: clientDependencyName, package: clientDependencyName),
                .product(name: clientExecutableName, package: clientDependencyName),
            ],
            path: "Tests/\(integrationTargetName)"
        )
    ]
)
