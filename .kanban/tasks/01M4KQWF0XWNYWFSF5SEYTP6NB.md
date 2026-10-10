---
assignees:
- claude-code
position_column: todo
position_ordinal: '9280'
title: 'Make `swift package update` work again: SwiftPM 6.4 ignores the root swift-otel traits'
---
## Problem

`swift package update` (all packages or one package) fails in the root package each time with "exhausted attempts to resolve the dependencies graph ... grpc-swift-2, grpc-swift-nio-transport, grpc-swift-protobuf". `swift package resolve` passes.

## Cause (proved 2026-10-10, task ^85k28zk)

- A scratch package that has only `.package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.5.1", traits: ["OTLPHTTP"])` gives the same error on `swift package update` with Swift 6.4 (Xcode 27.0). `swift package resolve` passes on it.
- SwiftPM `update` does not apply the traits that the ROOT manifest sets on a dependency. It then asks for the OTLPGRPC dependencies of swift-otel (default traits), which the resolver did not fetch.
- Before FoundationModelsACPClient 24643be, the client also declared swift-otel with `OTLPHTTP` (a non-root parent), and the update could pass (sometimes after retries). 24643be removed that declaration.

## What to do

- Find a manifest form that `update` accepts and that keeps gRPC out of the graph (for example, check if a newer SwiftPM fixes it; check a form where a non-root target package declares the trait). Do not edit Package.resolved by hand.
- Add a check (or a documented command) that proves `swift package update` passes.
- Report the SwiftPM defect upstream if no fix exists.

## Acceptance

- [ ] `swift package --scratch-path <path> update <one package>` passes in the root package.
- [ ] Package.resolved holds no grpc pin after the update.