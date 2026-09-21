// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The root package this one evaluates, reached by path.
private let rootPackageName = "FoundationModelsACPAgent"

/// The name of this package and of its one test target.
///
/// The name does not use the word `Evaluations` alone, because Apple's
/// evaluation framework already gives a module that name, and the eval
/// sources import it.
private let evaluationTargetName = "\(rootPackageName)EvaluationTests"

/// The root package's shared test-support product (plan.md §20.1): the
/// in-process harness, the scripted model, and the stub profile fixtures.
/// The unit target and the integration package link the same product, so
/// the three sides cannot drift apart.
private let testSupportProductName = "\(rootPackageName)TestSupport"

/// The base URL of the packages under the swissarmyhammer GitHub
/// organization, as the root manifest declares them.
private let swissArmyHammerOrgURL = "git@github.com:swissarmyhammer/"

/// The branch each family sibling is tracked on, as the root manifest
/// declares it.
private let mainBranch = "main"

/// The ACP wire (plan.md §1). The subject asserts on wire types.
private let wireDependencyName = "FoundationModelsACP"

/// The Client role (plan.md §20.1): the driver the subject prompts through.
private let clientDependencyName = "FoundationModelsACPClient"

/// The runtime (plan.md §1). The evaluation reads Router's session types,
/// and Router's test-support product carries `MetalLibraryTestBootstrap`.
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

/// The products the live-loader construction of the evaluation links.
private let liveLoaderProducts: [Target.Dependency] = [
    .product(name: "MLXLMCommon", package: mlxPackage),
    .product(name: "MLXHuggingFace", package: mlxPackage),
    .product(name: "HuggingFace", package: huggingFacePackage),
    .product(name: "Tokenizers", package: transformersPackage),
]

/// SwiftPM manifest for the evaluations of FoundationModelsACPAgent
/// (plan.md §20.3).
///
/// This package is the third and last test level. The unit level and the
/// integration level answer "is the code correct", and a failure there is
/// a defect. The integration level loads a small real model only for a fact
/// that holds in every measured run, such as the skill trigger gate. This
/// level answers "does a local model, driven end to end, choose to use
/// the tools and succeed". A score below the floor can be a model
/// question, not a code defect, and one whole-dataset drive takes hours.
///
/// Those two properties are why this package stands apart from
/// `IntegrationTests` and why CI never runs it. Sharing one `swift test`
/// with the integration suites gave the two one exit code, so a model
/// that had an off night marked the process-boundary contract broken and
/// a real contract regression had nowhere to show.
///
/// Run it on demand:
///
///     swift test --package-path EvaluationTests
///
/// or through the `Evaluation` workflow, which is
/// `workflow_dispatch` only.
let package = Package(
    name: evaluationTargetName,
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
            name: evaluationTargetName,
            dependencies: [
                .product(name: rootPackageName, package: rootPackageName),
                .product(name: testSupportProductName, package: rootPackageName),
                .product(name: wireDependencyName, package: wireDependencyName),
                .product(name: clientDependencyName, package: clientDependencyName),
                .product(name: routerDependencyName, package: routerDependencyName),
                .product(
                    name: "\(routerDependencyName)TestSupport", package: routerDependencyName),
            ] + liveLoaderProducts,
            path: "Tests/\(evaluationTargetName)"
        )
    ]
)
