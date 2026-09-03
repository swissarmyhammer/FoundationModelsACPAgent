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

/// The agent example executable of the root package (plan.md §20.2). It is
/// a product dependency, so SwiftPM builds the binary into the products
/// directory beside this test bundle, where `BuiltProductLocator` finds it
/// and `StdioContractTests` spawns it.
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

/// The ACP wire (plan.md §1). The tier-3 suites assert on wire types.
private let wireDependencyName = "FoundationModelsACP"

/// The Client role (plan.md §20.1): the driver of every integration tier.
private let clientDependencyName = "FoundationModelsACPClient"

/// The runtime (plan.md §1). The eval reads Router's session types, and
/// Router's test-support product carries `MetalLibraryTestBootstrap`.
private let routerDependencyName = "FoundationModelsRouter"

/// The MLX-backed model package, declared by the exact URL Router
/// declares, because a second location for one package identity makes the
/// resolve fail.
private let mlxPackage = "mlx-swift-lm"

/// The `mlxPackage` branch, matching Router's own declaration.
private let mlxStableBranch = "stable"

/// The Hugging Face Hub client package. The `#hubDownloader()` macro
/// expands to code that references `HuggingFace.HubClient`.
private let huggingFacePackage = "swift-huggingface"

/// The Swift Transformers tokenizer package, paired with
/// `huggingFacePackage`: the `#huggingFaceTokenizerLoader()` macro
/// expansion references `Tokenizers.AutoTokenizer`.
private let transformersPackage = "swift-transformers"

/// The products the live-loader construction of the tier-4 eval links.
private let liveLoaderProducts: [Target.Dependency] = [
    .product(name: "MLXLMCommon", package: mlxPackage),
    .product(name: "MLXHuggingFace", package: mlxPackage),
    .product(name: "HuggingFace", package: huggingFacePackage),
    .product(name: "Tokenizers", package: transformersPackage),
]

/// SwiftPM manifest for the integration suites of FoundationModelsACPAgent.
///
/// This package exists so that `swift test` at the repository root runs the
/// unit suites and only the unit suites, as the org test contract asks. The
/// suites here spawn built binaries across a real process boundary, load
/// real models, and reach the network, so they run through
/// `swift test --package-path IntegrationTests` and through the shared CI
/// workflow's integration job. No environment variable selects them.
let package = Package(
    name: integrationTargetName,
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "\(swissArmyHammerOrgURL)\(wireDependencyName).git", branch: mainBranch),
        .package(url: "\(swissArmyHammerOrgURL)\(clientDependencyName).git", branch: mainBranch),
        .package(url: "\(swissArmyHammerOrgURL)\(routerDependencyName).git", branch: mainBranch),
        .package(url: "https://github.com/swissarmyhammer/\(mlxPackage)", branch: mlxStableBranch),
        .package(url: "https://github.com/huggingface/\(huggingFacePackage)", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/\(transformersPackage)", from: "1.3.0"),
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
                .product(name: routerDependencyName, package: routerDependencyName),
                .product(
                    name: "\(routerDependencyName)TestSupport", package: routerDependencyName),
            ] + liveLoaderProducts,
            path: "Tests/\(integrationTargetName)"
        )
    ]
)
