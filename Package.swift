// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The name of this package, its library product, and its library target.
private let packageName = "FoundationModelsACPAgent"

/// The name of the unit test target, under `Tests/`.
private let testTargetName = "\(packageName)Tests"

/// The base URL of the packages under the swissarmyhammer GitHub organization.
///
/// Each family sibling is a remote dependency on its `main` branch, never a
/// local `path:` one. That is the family convention: the shared CI workflow
/// checks out one repository only, and a path dependency would not exist
/// there. A remote reference also keeps SwiftPM's "Conflicting identity"
/// warning away, because one package reached by path here and by URL from
/// another node of the graph is what that warning reports.
private let swissArmyHammerOrgURL = "git@github.com:swissarmyhammer/"

/// The branch each family sibling is tracked on.
///
/// A branch and not a version: Multitool has no semver tags, and Skills
/// publishes none either, so a `from:` requirement does not resolve. A branch
/// carries no compatible-range promise; `Package.resolved` pins one revision
/// of it until `swift package update` moves it.
private let mainBranch = "main"

/// The ACP wire (plan.md §1): the generated types, the role protocols, the
/// connections, and the ndJSON framing. It has zero dependencies.
private let wireDependencyName = "FoundationModelsACP"

/// The runtime (plan.md §1): self-folding, token-metered, event-streaming,
/// recorded sessions.
private let routerDependencyName = "FoundationModelsRouter"

/// The dotfolder stack, the template engine, and the operation-event
/// vocabulary (plan.md §1).
private let extrasDependencyName = "FoundationModelsExtras"

/// The consolidated tool surface (plan.md §1): the files, shell and mcp
/// capabilities behind one code-mode tool. The former FileTool, Shelltool
/// and MCP packages dissolved into it, so none of the three is declared here.
private let multitoolDependencyName = "FoundationModelsMultitool"

/// The stand-alone skills package (plan.md §1). It gives a plain
/// `FoundationModels.Tool`. It is NOT a Multitool capability, so a skill loads
/// in one request/response and not through the async code-mode lane.
private let skillsDependencyName = "FoundationModelsSkills"

/// The Client role (plan.md §20.1): the driver of every integration tier.
///
/// The test target alone links it. The library target never does. The client
/// depends on the wire and Extras only, so no cycle is possible.
private let clientDependencyName = "FoundationModelsACPClient"

/// The MLX-backed model package Router itself builds on, declared by the
/// exact URL Router declares — `https://github.com/swissarmyhammer/` plus
/// this name — because a second location for one package identity makes
/// the resolve fail. The example executable links two of its products to
/// construct a live `LiveModelLoader` through the `#hubDownloader()` and
/// `#huggingFaceTokenizerLoader()` macros. The resolved graph already
/// carries all of mlx-swift-lm transitively through Router, so this
/// declaration adds linking only, no new compilation.
private let mlxPackage = "mlx-swift-lm"

/// The `mlxPackage` branch, matching Router's own declaration: `stable`
/// is a published snapshot, not a working copy.
private let mlxStableBranch = "stable"

/// The Hugging Face Hub client package. The `#hubDownloader()` macro
/// expands to code that references `HuggingFace.HubClient`, so the
/// example target must link it. The version floor mirrors Router's.
private let huggingFacePackage = "swift-huggingface"

/// The Swift Transformers tokenizer package, paired with
/// `huggingFacePackage`: the `#huggingFaceTokenizerLoader()` macro
/// expansion references `Tokenizers.AutoTokenizer`.
private let transformersPackage = "swift-transformers"

/// The products the example's live-loader construction links, beside the
/// library and the wire — see `mlxPackage`.
private let liveLoaderProducts: [Target.Dependency] = [
    .product(name: "MLXLMCommon", package: mlxPackage),
    .product(name: "MLXHuggingFace", package: mlxPackage),
    .product(name: "HuggingFace", package: huggingFacePackage),
    .product(name: "Tokenizers", package: transformersPackage),
]

/// The name of the example executable (plan.md §20.2): the family
/// convention example AND the tier-3 stdio fixture. The test target
/// depends on it, so `swift test` builds the binary into the products
/// directory where the gated `StdioContractTests` spawns it.
private let exampleExecutableName = "acp-agent"

/// The MCP swift-sdk, reached through the organization fork
/// `https://github.com/swissarmyhammer/swift-sdk` — the exact URL Multitool
/// declares, because a second URL for the same package identity makes the
/// resolve fail. The MCP composition (plan.md §11.5) names the sdk's
/// `HTTPClientTransport` for the http transport of a composed server.
private let mcpSDKPackage = "swift-sdk"

/// The one product of `mcpSDKPackage` this package links.
private let mcpSDKProduct = Target.Dependency.product(name: "MCP", package: mcpSDKPackage)

/// Router's hermetic test-support product (plan.md §20.1). The gated
/// tier-4 eval reads `MetalLibraryTestBootstrap.ensureColocatedMetallib`
/// from it before the first GPU evaluation: under `swift test`,
/// mlx-swift does not find its shader library beside the test binary
/// on its own, and the bootstrap symlinks it once per process.
private let routerTestSupportProduct = Target.Dependency.product(
    name: "\(routerDependencyName)TestSupport", package: routerDependencyName)

/// The test-support products of Multitool (plan.md §20): the `MCPTestServer`
/// scripted-server library, and the `mcp-test-server` stdio executable the
/// MCP composition suite spawns. The executable is a product dependency so
/// `swift test` builds it into the products directory beside the test
/// bundle, where `BuiltProductLocator` finds it.
private let multitoolTestProducts: [Target.Dependency] = [
    .product(name: "MCPTestServer", package: multitoolDependencyName),
    .product(name: "mcp-test-server", package: multitoolDependencyName),
]

/// The five family packages the library target depends on (plan.md §1).
///
/// Router and Extras are declared by name, and not reached through Multitool:
/// Multitool has no `@_exported import`, so its dependencies do not come for
/// free. The MCP composition (plan.md §11.5) names `MCP.Transport` types for
/// its http path, so `mcpSDKPackage` declares the sdk as well.
private let familyDependencyNames = [
    wireDependencyName,
    routerDependencyName,
    extrasDependencyName,
    multitoolDependencyName,
    skillsDependencyName,
]

/// Makes the `.package(url:branch:)` dependency of a family package hosted
/// under `swissArmyHammerOrgURL`, tracking `mainBranch`.
private func makeFamilyPackage(name: String) -> Package.Dependency {
    .package(url: "\(swissArmyHammerOrgURL)\(name).git", branch: mainBranch)
}

/// Makes the product dependency of a family package. Each family package
/// ships one library product with the package's own name.
private func makeFamilyProduct(name: String) -> Target.Dependency {
    .product(name: name, package: name)
}

/// The library products of `familyDependencyNames`, linked by the library
/// target and by the test target. The test target imports each module
/// directly, so it declares each product it imports.
private let familyProducts = familyDependencyNames.map(makeFamilyProduct(name:))

/// SwiftPM manifest for FoundationModelsACPAgent.
///
/// The composed agent (plan.md): `AgentConfiguration` over the dotfolder
/// stack, the tool roster, the slash-command registry, and `RoutedACPAgent`,
/// the ACP `Agent` conformance over Router sessions.
let package = Package(
    name: packageName,
    // macOS only, matching the family. Router's floor is macOS 27 /
    // FoundationModels v2. Every sibling manifest — Extras, Router, Multitool
    // and Skills — declares the string form `.macOS("27.0")`, because `.v27`
    // needs PackageDescription 6.4 and these manifests are tools-version 6.2.
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: packageName, targets: [packageName]),
        // The runnable example, published so `swift run acp-agent` and
        // the tier-3 spawn name one binary — see `exampleExecutableName`.
        .executable(name: exampleExecutableName, targets: [exampleExecutableName]),
    ],
    dependencies: familyDependencyNames.map(makeFamilyPackage(name:)) + [
        makeFamilyPackage(name: clientDependencyName),
        // The sdk fork, by the same URL Multitool declares — see
        // `mcpSDKPackage`.
        .package(url: "https://github.com/swissarmyhammer/\(mcpSDKPackage).git", branch: mainBranch),
        // The live-loader packages of the example executable — see
        // `mlxPackage`, `huggingFacePackage` and `transformersPackage`.
        .package(url: "https://github.com/swissarmyhammer/\(mlxPackage)", branch: mlxStableBranch),
        .package(url: "https://github.com/huggingface/\(huggingFacePackage)", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/\(transformersPackage)", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: familyProducts + [mcpSDKProduct]
        ),
        // The example executable (plan.md §20.2): the composition lesson
        // and the tier-3 fixture in one small `main.swift`. It links the
        // library, the wire and Router directly for what it imports, and
        // the live-loader products for the real model path.
        .executableTarget(
            name: exampleExecutableName,
            dependencies: [
                .target(name: packageName),
                makeFamilyProduct(name: wireDependencyName),
                makeFamilyProduct(name: routerDependencyName),
            ] + liveLoaderProducts,
            path: "Examples/\(exampleExecutableName)"
        ),
        // The import smoke suite. It links the client driver as well — see
        // `clientDependencyName` — Multitool's test-support products — see
        // `multitoolTestProducts` — the MCP sdk, whose tool-result
        // content types the passthrough-map tests construct (plan.md §12),
        // the example executable, so `swift test` builds the tier-3
        // fixture beside the test bundle — see `exampleExecutableName` —
        // and the live-loader products, so the gated tier-4 eval
        // (plan.md §20.3) constructs the same real `LiveModelLoader` the
        // example does. The graph already carries them; this adds linking
        // only — see `liveLoaderProducts`.
        .testTarget(
            name: testTargetName,
            dependencies: [
                .target(name: packageName),
                .target(name: exampleExecutableName),
                makeFamilyProduct(name: clientDependencyName),
            ]
                + familyProducts + multitoolTestProducts + [mcpSDKProduct]
                + liveLoaderProducts + [routerTestSupportProduct]
        ),
    ]
)
