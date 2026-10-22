import CryptoKit
import Foundation
import FoundationModelsCodeContext
import Marketplace

/// The one home of a host (task ^98a44n7): each folder outside the project
/// that the agent reads or writes comes from it.
///
/// A home has two roots:
///
/// - ``synced``: the data of the user that must follow the user from device
///   to device. The user layer of each settings stack (`config.yaml`,
///   `Instructions.md`, the skills, the agents and the rules) and the
///   projects folder (``projectsDirectory``) are in it.
/// - ``local``: the state of this machine, which never syncs. The hook data
///   (the snapshot timelines point into a local git checkout), the caches,
///   and the machine state of each project (``projectStateDirectory(of:)``)
///   are in it.
///
/// The host chooses the home. The `acp-agent` CLI uses the XDG preset
/// ``xdg(name:environment:)``, which keeps the folders that the CLI always
/// used. An app gives its own two roots with ``custom(synced:local:)``, for
/// example a folder in its iCloud container and a folder in Application
/// Support. This package holds no app path.
///
/// The session data of a project stays in the project folder: the
/// transcripts in `<cwd>/.<name>/transcripts`, and the session layer of the
/// settings in `<cwd>/.<name>/config.yaml`.
public struct AgentHome: Sendable, Equatable {
    /// Where the user layer of each settings stack is in the home.
    enum SettingsLayout: Sendable, Equatable {
        /// The XDG layout of the CLI: the user layer of each kind is the
        /// folder of its own dotfolder name in the XDG configuration home,
        /// `<configHome>/<dotfolder>/`.
        case xdg(configHome: URL)

        /// The layout of a host root: each user layer is in ``synced``. The
        /// configuration and the agents are in the root itself, the skills
        /// in `_skills/`, and the rules in `_rules/` (``SettingsFolders``).
        case rooted
    }

    // MARK: - Constants

    /// The folder of the projects in ``synced``.
    static let projectsFolderName = "projects"

    /// The folder of the hook data in ``local``.
    static let hooksFolderName = "hooks"

    /// The folder of the skills marketplace cache in the local root of a
    /// custom home.
    static let skillsMarketplaceFolderName = "skills-marketplace"

    /// The folder of the model cache in the local root of a custom home.
    static let modelsFolderName = "models"

    /// The folder of the metadata cache of the router in the local root of a
    /// custom home.
    static let routerFolderName = "router"

    /// The folder of the install record of the language servers in the local
    /// root of a custom home.
    static let languageServersFolderName = "language-servers"

    /// The environment key of the base directory of the user configuration
    /// files, in the XDG Base Directory specification.
    static let configHomeEnvironmentKey = "XDG_CONFIG_HOME"

    /// The base directory of the user configuration files when
    /// `XDG_CONFIG_HOME` is not an absolute path, relative to the home
    /// directory.
    static let defaultConfigHomePath = ".config"

    /// The environment key of the base directory of the user data files, in
    /// the XDG Base Directory specification.
    static let dataHomeEnvironmentKey = "XDG_DATA_HOME"

    /// The base directory of the user data files when `XDG_DATA_HOME` is not
    /// an absolute path, relative to the home directory.
    static let defaultDataHomePath = ".local/share"

    /// The format of one byte of the project key: two lowercase hexadecimal
    /// digits.
    private static let digestByteFormat = "%02x"

    // MARK: - Stored state

    /// The root of the data that follows the user.
    public let synced: URL

    /// The root of the state of this machine.
    public let local: URL

    /// The folder where the hooks keep their data. The snapshot timeline of
    /// each session goes into its `snapshot` folder.
    public let hooksDirectory: URL

    /// The cache folder of the skills marketplace store of each session. The
    /// marketplace agents come from the same store.
    public let skillsMarketplaceCacheDirectory: URL

    /// The Hugging Face hub cache folder of the models. A live router
    /// downloads each model into it, and `doctor` prices the downloads
    /// against it.
    public let modelCacheDirectory: URL

    /// The metadata cache folder of the router (`Router.init(cacheDir:)`),
    /// or `nil` for the folder that the router chooses itself. The XDG
    /// preset gives `nil`, thus the CLI keeps the folder of today.
    public let routerCacheDirectory: URL?

    /// The folder of the install record of the language servers of the code
    /// context (`LspAutoInstall.failureRecordDirectory`), or `nil` for no
    /// record. The XDG preset gives the default folder of the code context,
    /// thus the CLI keeps the folder of today.
    public let languageServerInstallRecordDirectory: URL?

    /// Where the user layer of each settings stack is.
    let settingsLayout: SettingsLayout

    // MARK: - Presets

    /// The home of a host that gives its own two roots. Each folder of the
    /// home is in one of them, and the home reads no environment variable
    /// and no folder of the user's home directory.
    ///
    /// - Parameters:
    ///   - synced: The root of the data that follows the user.
    ///   - local: The root of the state of this machine.
    /// - Returns: The home.
    public static func custom(synced: URL, local: URL) -> AgentHome {
        AgentHome(
            synced: synced,
            local: local,
            hooksDirectory: local.appendingPathComponent(hooksFolderName, isDirectory: true),
            skillsMarketplaceCacheDirectory: local.appendingPathComponent(
                skillsMarketplaceFolderName, isDirectory: true),
            modelCacheDirectory: local.appendingPathComponent(modelsFolderName, isDirectory: true),
            routerCacheDirectory: local.appendingPathComponent(routerFolderName, isDirectory: true),
            languageServerInstallRecordDirectory: local.appendingPathComponent(
                languageServersFolderName, isDirectory: true),
            settingsLayout: .rooted)
    }

    /// The XDG home of the `acp-agent` CLI, with the folders that the CLI
    /// always used:
    ///
    /// - ``synced`` is `$XDG_CONFIG_HOME/<name>/`, and the user layer of each
    ///   settings stack is `$XDG_CONFIG_HOME/<dotfolder>/`.
    /// - ``local`` is `$XDG_DATA_HOME/<name>/`, and the hooks are in its
    ///   `hooks` folder.
    /// - The caches stay the shared caches of the environment: the skills
    ///   marketplace cache of `MarketplaceStore.cacheDirectory(environment:)`
    ///   (`SKILLS_MARKETPLACE_CACHE`, or its default folder), and the Hugging
    ///   Face hub cache of ``SystemModelResolver/hubCacheDirectory(environment:modelCacheDirectory:)``.
    ///
    /// An XDG variable that is not an absolute path is not valid in the XDG
    /// Base Directory specification, thus it gives the default folder under
    /// the home directory.
    ///
    /// - Parameters:
    ///   - name: The dotfolder name of the host.
    ///   - environment: The environment that the XDG variables and the cache
    ///     variables are read from.
    /// - Returns: The home.
    public static func xdg(name: DotfolderName, environment: [String: String]) -> AgentHome {
        let configHome = baseDirectory(
            environment: environment, key: configHomeEnvironmentKey, defaultPath: defaultConfigHomePath)
        let local = baseDirectory(
            environment: environment, key: dataHomeEnvironmentKey, defaultPath: defaultDataHomePath
        ).appendingPathComponent(name.rawValue, isDirectory: true)
        return AgentHome(
            synced: configHome.appendingPathComponent(name.rawValue, isDirectory: true),
            local: local,
            hooksDirectory: local.appendingPathComponent(hooksFolderName, isDirectory: true),
            skillsMarketplaceCacheDirectory: MarketplaceStore.cacheDirectory(environment: environment),
            modelCacheDirectory: SystemModelResolver.hubCacheDirectory(environment: environment),
            routerCacheDirectory: nil,
            languageServerInstallRecordDirectory: LspAutoInstall.defaultFailureRecordDirectory,
            settingsLayout: .xdg(configHome: configHome))
    }

    // MARK: - Derived folders

    /// The projects folder in ``synced``: the folder of the project store
    /// of the host (Router `ProjectStore`, task ^am394r2).
    public var projectsDirectory: URL {
        synced.appendingPathComponent(Self.projectsFolderName, isDirectory: true)
    }

    /// The folder of the machine state of one project:
    /// `<local>/projects/<key>/`, where the key is the lowercase hexadecimal
    /// SHA-256 of the standardized path of `workingDirectory`.
    ///
    /// The state of a project that belongs to this machine goes here, and
    /// never into the project folder, because the project folder can be in
    /// ``synced``: the index of the code context (a live SQLite database) and
    /// the log of the shell.
    ///
    /// - Parameter workingDirectory: The working directory of the project.
    /// - Returns: The folder. The call does not make it.
    public func projectStateDirectory(of workingDirectory: URL) -> URL {
        local.appendingPathComponent(Self.projectsFolderName, isDirectory: true)
            .appendingPathComponent(Self.projectKey(of: workingDirectory), isDirectory: true)
    }

    /// The user layer root of a settings stack.
    ///
    /// - Parameters:
    ///   - dotfolder: The dotfolder name of the stack: the folder of the
    ///     stack in the XDG configuration home.
    ///   - folderInRoot: The folder of the stack in ``synced`` with the
    ///     rooted layout, or `nil` for ``synced`` itself.
    /// - Returns: The folder.
    func userLayerRoot(dotfolder: String, folderInRoot: String?) -> URL {
        switch settingsLayout {
        case .xdg(let configHome):
            return configHome.appendingPathComponent(dotfolder, isDirectory: true)
        case .rooted:
            guard let folderInRoot else {
                return synced
            }
            return synced.appendingPathComponent(folderInRoot, isDirectory: true)
        }
    }

    // MARK: - Helpers

    /// The key of one project: the lowercase hexadecimal SHA-256 of the
    /// standardized path of its working directory.
    ///
    /// - Parameter workingDirectory: The working directory of the project.
    /// - Returns: The key, one safe path component.
    private static func projectKey(of workingDirectory: URL) -> String {
        SHA256.hash(data: Data(workingDirectory.standardizedFileURL.path.utf8))
            .map { String(format: digestByteFormat, $0) }
            .joined()
    }

    /// One XDG base directory: the absolute folder that `key` of
    /// `environment` names, or `defaultPath` under the home directory.
    ///
    /// - Parameters:
    ///   - environment: The environment to read.
    ///   - key: The XDG variable.
    ///   - defaultPath: The default folder, relative to the home directory.
    /// - Returns: The folder.
    private static func baseDirectory(
        environment: [String: String], key: String, defaultPath: String
    ) -> URL {
        guard let path = environment[key], path.hasPrefix("/") else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(defaultPath, isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
