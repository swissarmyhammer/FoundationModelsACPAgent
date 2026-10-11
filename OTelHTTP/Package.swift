// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// The name of this package, its library product, and its library target.
private let packageName = "OTelHTTP"

/// The OpenTelemetry backend package: the OTLP exporters of traces, logs and
/// metrics, and `OTel.bootstrap`.
private let otelPackage = "swift-otel"

/// The version floor of `otelPackage`. 1.5.1 is the newest release, and it
/// builds with the swift-log, swift-metrics and swift-distributed-tracing
/// versions that the graph of the agent resolves.
private let otelVersionFloor: Version = "1.5.1"

/// The traits of `otelPackage` that the agent turns on. The agent exports
/// OTLP over HTTP only. The default traits of `swift-otel` also turn on
/// `OTLPGRPC`, which compiles three gRPC packages that the agent does not
/// use. SwiftPM joins the traits of each package in the graph, so each
/// package of the graph that depends on `swift-otel` must name only this
/// trait.
private let otelTraits: Set<Package.Dependency.Trait> = ["OTLPHTTP"]

/// SwiftPM manifest for OTelHTTP.
///
/// The telemetry backend of the `acp-agent` executable: `swift-otel` with the
/// `OTLPHTTP` trait only. The module re-exports `OTel`.
///
/// This local package, and not the root manifest, declares `swift-otel`. It
/// is a workaround for a SwiftPM 6.4 defect,
/// swiftlang/swift-package-manager#10397. `swift package update` clears the
/// enabled-traits map and does not load the ROOT manifest again, so the
/// traits that the root sets on a dependency are lost. `swift-otel` then
/// falls back to its default traits, and the update stops with "exhausted
/// attempts to resolve the dependencies graph" on the three gRPC packages. A
/// local path package is loaded again as a dependency, so the traits that it
/// sets stay. The root must not declare `swift-otel` too: its lost request
/// then makes the result depend on the load order. The fix (#10547) is in the
/// `release/6.4.1` branch. When the toolchain is 6.4.1 or later, the root
/// manifest can declare `swift-otel` itself again, and this folder can go.
let package = Package(
    name: packageName,
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: packageName, targets: [packageName])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swift-otel/\(otelPackage).git", from: otelVersionFloor, traits: otelTraits)
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: [.product(name: "OTel", package: otelPackage)]
        )
    ]
)
