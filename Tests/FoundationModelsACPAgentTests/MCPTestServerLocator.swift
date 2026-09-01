// `MCPTestServerLocator` — where the `mcp-test-server` binary stands.
//
// A behavioral port of
// `../FoundationModelsMultitool/Tests/FoundationModelsMultitoolTests/Support/TestServerLocator.swift`.
// The test target of this package declares the `mcp-test-server` executable
// product of Multitool as a dependency, so `swift test` builds the binary
// into the products directory beside this test bundle. This locator finds
// it there, for each test that spawns it through the MCP composition.

import Foundation

/// Locates the `mcp-test-server` executable that SwiftPM builds beside the
/// running test binary — so the `--test-bundle-path` / `.xctest`
/// products-directory resolution stands in one place.
enum MCPTestServerLocator {
    /// The product name of the executable, as Multitool's `Package.swift`
    /// declares it.
    static let executableName = "mcp-test-server"

    /// The flag `swiftpm-testing-helper` passes the bundle path under.
    private static let testBundlePathFlag = "--test-bundle-path"

    /// The suffix of a test bundle path, the fallback when
    /// ``testBundlePathFlag`` is absent.
    private static let testBundleSuffix = ".xctest"

    /// The path component that walks up one directory, which no argument
    /// this locator reads may carry.
    private static let parentDirectoryComponent = ".."

    /// How many path components stand between the executable inside a test
    /// bundle (`<Bundle>.xctest/Contents/MacOS/<binary>`) and the products
    /// directory that holds the bundle: the binary, `MacOS`, `Contents` and
    /// the bundle itself.
    private static let bundleDepthBelowProductsDirectory = 4

    /// The failures of this locator.
    enum LocatorError: Error, CustomStringConvertible {
        /// `argumentName` (`value`) carried a `..` path component.
        case pathTraversalRejected(argumentName: String, value: String)

        /// The candidate at `path`, derived from `derivedFromArgument`, is
        /// not a directory.
        case productsDirectoryNotFound(path: String, derivedFromArgument: String)

        /// No executable file stands at `path`.
        case testServerNotFound(path: String)

        /// A human-readable description of this error.
        var description: String {
            switch self {
            case .pathTraversalRejected(let argumentName, let value):
                return
                    "Rejected \(argumentName) argument \"\(value)\": a \"..\" path component is not allowed when deriving the test products directory."
            case .productsDirectoryNotFound(let path, let derivedFromArgument):
                return
                    "Derived products directory \"\(path)\" (from argument \"\(derivedFromArgument)\") does not exist or is not a directory; the test-bundle argument parsing may no longer match this build's layout."
            case .testServerNotFound(let path):
                return
                    "Could not find the \(executableName) executable at \(path); `swift test` builds it because the test target depends on the executable product."
            }
        }
    }

    /// Locates the build products directory that holds the running test
    /// binary — `.build/debug`, for example — so that ``executableURL()``
    /// can find the sibling `mcp-test-server` SwiftPM built beside it.
    ///
    /// On Darwin, `swift test` hosts the swift-testing runner inside an
    /// `.xctest` bundle that a separate `swiftpm-testing-helper` process
    /// launches with a `--test-bundle-path` argument — read here, and not
    /// through `Bundle.allBundles`, because that bundle never registers as
    /// an `NSBundle`. A run that invokes the built bundle directly through
    /// `xcrun xctest <bundle>` sets no such flag; there the bundle path is
    /// the positional argument with the `.xctest` suffix, and its parent is
    /// the products directory. When neither applies, the directory of this
    /// process's own executable is the products directory.
    ///
    /// Every candidate goes through the `..` check before it derives a
    /// path, and the derived directory through the existence check before
    /// it is returned: a `CommandLine` argument must not walk this
    /// resolution outside the real products directory.
    ///
    /// - Returns: The products directory.
    /// - Throws: ``LocatorError`` when the argument carries a `..`
    ///   component, or when the derived candidate is not a directory.
    static func productsDirectoryURL() throws -> URL {
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: testBundlePathFlag),
            arguments.indices.contains(flagIndex + 1)
        {
            return try productsDirectory(
                derivedFrom: arguments[flagIndex + 1], argumentName: testBundlePathFlag,
                levelsUp: bundleDepthBelowProductsDirectory)
        }
        if let bundleArgument = arguments.first(where: { $0.hasSuffix(testBundleSuffix) }) {
            return try productsDirectory(
                derivedFrom: bundleArgument,
                argumentName: "the \(testBundleSuffix)-suffixed argument", levelsUp: 1)
        }
        return try productsDirectory(
            derivedFrom: arguments[0], argumentName: "CommandLine.arguments[0]", levelsUp: 1)
    }

    /// Derives the products directory from one `CommandLine` argument: the
    /// `..` check, `levelsUp` parent steps, then the directory check — the
    /// one sequence every branch of ``productsDirectoryURL()`` runs.
    ///
    /// - Parameters:
    ///   - argument: The argument value to derive from.
    ///   - argumentName: A label for `argument`, for the error only.
    ///   - levelsUp: How many trailing path components to remove.
    /// - Returns: The derived directory.
    /// - Throws: ``LocatorError/pathTraversalRejected(argumentName:value:)``
    ///   or ``LocatorError/productsDirectoryNotFound(path:derivedFromArgument:)``.
    private static func productsDirectory(
        derivedFrom argument: String, argumentName: String, levelsUp: Int
    ) throws -> URL {
        guard !argument.split(separator: "/").contains(Substring(parentDirectoryComponent)) else {
            throw LocatorError.pathTraversalRejected(argumentName: argumentName, value: argument)
        }
        var candidate = URL(fileURLWithPath: argument)
        for _ in 0..<levelsUp {
            candidate = candidate.deletingLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw LocatorError.productsDirectoryNotFound(
                path: candidate.path, derivedFromArgument: argument)
        }
        return candidate
    }

    /// Locates the `mcp-test-server` executable SwiftPM built beside the
    /// running test binary.
    ///
    /// - Returns: The file URL of the executable.
    /// - Throws: ``LocatorError`` when ``productsDirectoryURL()`` rejects the
    ///   resolution, or when no executable file stands at the expected path.
    static func executableURL() throws -> URL {
        let candidate = try productsDirectoryURL().appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw LocatorError.testServerNotFound(path: candidate.path)
        }
        return candidate
    }
}
