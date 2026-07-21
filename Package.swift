// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsACPAgent",
    // macOS only, matching the family (Router's floor is macOS 27 /
    // FoundationModels v2; `.v26` here mirrors the sibling manifests pending
    // a tools-version bump — see FoundationModelsExtras/Package.swift).
    platforms: [
        .macOS(.v26)
    ],
    products: [
        // The composed agent (plan.md): AgentConfiguration over the dotfolder
        // stack, the tool roster, the slash-command registry, and
        // HarnessACPAgent — the ACP `Agent` conformance over the harness.
        .library(name: "FoundationModelsACPAgent", targets: ["FoundationModelsACPAgent"])
    ],
    dependencies: [
        // Per plan.md §Layering, this package will depend on:
        //   FoundationModelsACP (the wire), FoundationModelsAgentHarness,
        //   FoundationModelsRouter, FoundationModelsExtras, and the roster's
        //   tool packages (FoundationModelsFileTool, FoundationModelsShelltool,
        //   FoundationModelsMCP).
        // Declared as the corresponding build-order steps land — the harness
        // and wire are plan-stage today, so the manifest starts dependency-free.
    ],
    targets: [
        .target(name: "FoundationModelsACPAgent")
    ]
)
