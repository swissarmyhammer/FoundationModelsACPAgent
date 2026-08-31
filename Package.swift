// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FoundationModelsACPAgent",
    // macOS only, matching the family. Router's floor is macOS 27 /
    // FoundationModels v2. Every sibling manifest — Extras, Router, Multitool
    // and Skills — declares the string form `.macOS("27.0")`, because `.v27`
    // needs PackageDescription 6.4 and these manifests are tools-version 6.2.
    // `.v26` below is a placeholder that will NOT resolve against those
    // dependencies; it changes to `.macOS("27.0")` when they are declared
    // (board task c3p8h6d).
    platforms: [
        .macOS(.v26)
    ],
    products: [
        // The composed agent (plan.md): AgentConfiguration over the dotfolder
        // stack, the tool roster, the slash-command registry, and
        // RoutedACPAgent — the ACP Agent conformance over Router sessions.
        .library(name: "FoundationModelsACPAgent", targets: ["FoundationModelsACPAgent"])
    ],
    dependencies: [
        // Per plan.md §1, this package will depend on FIVE packages:
        //   FoundationModelsACP (the wire), FoundationModelsRouter (the
        //   runtime: self-folding, event-streaming, recorded sessions),
        //   FoundationModelsExtras (the dotfolder stack, the template engine,
        //   and the OperationEvent vocabulary), FoundationModelsMultitool
        //   (the files, shell and MCP capabilities behind one code-mode
        //   surface), and FoundationModelsSkills — a standalone package
        //   giving a plain `Tool`, NOT a Multitool capability, so that a
        //   skill loads in one request/response rather than through the
        //   async code-mode lane.
        // Router and Extras must be named explicitly: Multitool has no
        //   `@_exported import`, so its dependencies do not come for free.
        // Use `branch: "main"` — Multitool and Skills publish no semver tags.
        // Declared as the corresponding board tasks land (c3p8h6d), so the
        // manifest starts dependency-free.
    ],
    targets: [
        .target(name: "FoundationModelsACPAgent")
    ]
)
