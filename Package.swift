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

/// The MCP swift-sdk, reached through the organization fork
/// `https://github.com/swissarmyhammer/swift-sdk` — the exact URL Multitool
/// declares, because a second URL for the same package identity makes the
/// resolve fail. The MCP composition (plan.md §11.5) names the sdk's
/// `HTTPClientTransport` for the http transport of a composed server.
private let mcpSDKPackage = "swift-sdk"

/// The one product of `mcpSDKPackage` this package links.
private let mcpSDKProduct = Target.Dependency.product(name: "MCP", package: mcpSDKPackage)

/// The test-support products of Multitool (plan.md §20): the `MCPTestServer`
/// scripted-server library, and the `mcp-test-server` stdio executable the
/// MCP composition suite spawns. The executable is a product dependency so
/// `swift test` builds it into the products directory beside the test
/// bundle, where `MCPTestServerLocator` finds it.
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
        .library(name: packageName, targets: [packageName])
    ],
    dependencies: familyDependencyNames.map(makeFamilyPackage(name:)) + [
        makeFamilyPackage(name: clientDependencyName),
        // The sdk fork, by the same URL Multitool declares — see
        // `mcpSDKPackage`.
        .package(url: "https://github.com/swissarmyhammer/\(mcpSDKPackage).git", branch: mainBranch),
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: familyProducts + [mcpSDKProduct]
        ),
        // The import smoke suite. It links the client driver as well — see
        // `clientDependencyName` — and Multitool's test-support products —
        // see `multitoolTestProducts`.
        .testTarget(
            name: testTargetName,
            dependencies: [.target(name: packageName), makeFamilyProduct(name: clientDependencyName)]
                + familyProducts + multitoolTestProducts
        ),
    ]
)
