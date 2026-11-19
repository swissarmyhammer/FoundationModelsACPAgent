// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The root package under measurement, reached by path.
private let rootPackageName = "FoundationModelsACPAgent"

/// The name of this package.
private let benchmarksPackageName = "\(rootPackageName)Benchmarks"

/// The name of the test target that measures the transcript search index.
private let transcriptSearchTargetName = "TranscriptSearchBenchmarks"

/// The root package's shared test-support product: `makeResolvedDirectory(label:)` and the
/// fake embedders (`CountingEmbedding`, `WordBucketEmbedding`). The root unit target links the
/// same product, so the measurement and the unit tests use one copy of each fake.
private let testSupportProductName = "\(rootPackageName)TestSupport"

/// The base URL of the packages under the swissarmyhammer GitHub organization, as the root
/// manifest declares them.
private let swissArmyHammerOrgURL = "git@github.com:swissarmyhammer/"

/// The branch each family sibling is tracked on, as the root manifest declares it.
private let mainBranch = "main"

/// The ACP wire: the session ids and the search chunks and requests of the measurement.
private let wireDependencyName = "FoundationModelsACP"

/// The runtime. The measurement imports it for `ULID`, which it re-exports: the transcript
/// search reads each session id as a ULID.
private let routerDependencyName = "FoundationModelsRouter"

/// The tool surface: the query parse and the request of the session search
/// (`SessionSearchQuery`, `SessionSearchRequest`) that the measurement gives to the index.
private let multitoolDependencyName = "FoundationModelsMultitool"

/// The logging API package. The measurement writes its report with a `Logger`. The root
/// manifest declares it from the same URL and the same floor.
private let loggingPackage = "swift-log"

/// The version floor of `loggingPackage`, matching the root manifest.
private let loggingVersionFloor: Version = "1.15.1"

/// SwiftPM manifest for the measurements of FoundationModelsACPAgent.
///
/// **Why this is a package of its own.** The root manifest does not name this package, the same
/// as `IntegrationTests/`. Thus a `swift test` at the root does not build or run it, and the CI
/// does not run it: a measurement runs only on demand. No environment variable selects it. The
/// test tool selects it with its package path:
///
///     swift test --package-path Benchmarks
///
/// **What `TranscriptSearchBenchmarks` holds.** The measurement of the transcript search index
/// with a realistic history (D207, ^y7nx1g3). It uses only the public API of the root package,
/// and it loads no model: its embedder is a fake with a fixed cost for each text.
///
/// The `.package(path: "..")` dependency is correct here. The family rule "no path dependency"
/// is for the root manifest, which the shared CI builds alone. The registry's `Benchmarks`
/// package and this repository's `IntegrationTests` package reach their root the same way.
let package = Package(
  name: benchmarksPackageName,
  // The same floor as the root package. A lower floor does not resolve against it.
  platforms: [
    .macOS("27.0")
  ],
  dependencies: [
    .package(path: ".."),
    .package(url: "\(swissArmyHammerOrgURL)\(wireDependencyName).git", branch: mainBranch),
    .package(url: "\(swissArmyHammerOrgURL)\(routerDependencyName).git", branch: mainBranch),
    .package(url: "\(swissArmyHammerOrgURL)\(multitoolDependencyName).git", branch: mainBranch),
    .package(url: "https://github.com/apple/\(loggingPackage).git", from: loggingVersionFloor),
  ],
  targets: [
    .testTarget(
      name: transcriptSearchTargetName,
      dependencies: [
        .product(name: rootPackageName, package: rootPackageName),
        .product(name: testSupportProductName, package: rootPackageName),
        .product(name: wireDependencyName, package: wireDependencyName),
        .product(name: routerDependencyName, package: routerDependencyName),
        .product(name: multitoolDependencyName, package: multitoolDependencyName),
        .product(name: "Logging", package: loggingPackage),
      ],
      path: "Tests/\(transcriptSearchTargetName)"
    )
  ]
)

// FoundationModelsRouter links llama.cpp through C++ modules, and a Swift target that imports a
// C++ module, directly or through a dependency, must build with C++ interoperability. Every
// target here reaches Router, so each non-plugin target takes the mode. The root `Package.swift`
// and `IntegrationTests/Package.swift` hold the same loop: a change to this rule changes the
// three manifests together.
// sah:allow duplication SwiftPM builds each manifest alone and a manifest cannot import a shared Swift file, so this loop is a known copy of the C++ interop loop of the root Package.swift
for target in package.targets where target.type != .plugin {
  target.swiftSettings = (target.swiftSettings ?? []) + [.interoperabilityMode(.Cxx)]
}
