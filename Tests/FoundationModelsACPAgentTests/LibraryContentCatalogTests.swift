import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The library part of the content catalog (D214, part 4): the agents, the skills and the MCP
/// servers of the user level and of each known folder.
@Suite struct LibraryContentCatalogTests {
  /// The id of the skill of a test.
  private static let skillID = "zebra-feeding"

  /// The id of the agent of a test.
  private static let agentID = "zookeeper"

  /// The command of the MCP server of a test: a secret that no record may hold.
  private static let secretCommand = "/opt/secret-tool"

  /// The environment value of the MCP server of a test: a secret that no record may hold.
  private static let secretValue = "token-zanzibar-1234"

  /// The text of a skill file.
  ///
  /// - Parameter id: The id of the skill.
  /// - Returns: The text.
  private static func skillMarkdown(_ id: String) -> String {
    "---\nname: \(id)\ndescription: Feed the zebra.\n---\nFeed the zebra each day.\n"
  }

  /// A catalog over the folders of `fixture`, with one known folder: the first folder of the
  /// fixture.
  ///
  /// - Parameters:
  ///   - fixture: The settings fixture.
  ///   - readable: The folder rule of the host.
  /// - Returns: The catalog.
  private static func catalog(
    of fixture: SettingsGraphFixture, readable: @escaping @Sendable (URL) -> Bool = { _ in true }
  ) -> LibraryContentCatalog {
    let directory = InMemorySessionDirectory()
    directory.register(
      SessionSummary(
        id: ULID.generate(), agentID: "default", workingDirectory: fixture.firstDirectory,
        tags: [], kind: .root, state: .idle, origin: .client, createdAt: Date(), updatedAt: Date(),
        isLive: false))
    return LibraryContentCatalog(
      settingsFolders: fixture.settingsFolders, store: fixture.store, directory: directory,
      readableFolder: readable, watches: LibraryWatches())
  }

  /// The project layer root of a kind for a folder.
  ///
  /// - Parameters:
  ///   - kind: The settings kind.
  ///   - fixture: The settings fixture.
  /// - Returns: The root.
  /// - Throws: A failed requirement when the stack has no project layer.
  private static func projectRoot(of kind: SettingsFolders.Kind, in fixture: SettingsGraphFixture)
    throws -> URL
  {
    try #require(
      fixture.settingsFolders.stack(for: kind, workingDirectory: fixture.firstDirectory).layers
        .first { $0.source == .project }?.root)
  }

  /// A new `SKILL.md` in a folder gives a record at the folder level, with its name, its
  /// description and its body, and the folder domain has a stamp.
  @Test func aSkillOfAFolderGivesARecordAtTheFolderLevel() async throws {
    let fixture = try SettingsGraphFixture(label: "library-skill")
    try writeSkillFixture(
      id: Self.skillID, markdown: Self.skillMarkdown(Self.skillID),
      under: try Self.projectRoot(of: .skills, in: fixture))
    let catalog = Self.catalog(of: fixture)
    let domain = LibraryDomain(kind: .skill, level: .folder(fixture.firstDirectory))

    let records = try await catalog.records(of: domain)

    #expect(records.map(\.id.name) == [Self.skillID])
    #expect(records.first?.description == "Feed the zebra.")
    #expect(records.first?.body?.contains("Feed the zebra each day.") == true)
    let stamps = try await catalog.stamps()
    #expect(stamps[LibraryDomain(kind: .skill, level: .folder(fixture.firstDirectory.standardizedFileURL))] != nil)
    #expect(stamps[LibraryDomain(kind: .skill, level: .user)] != nil)
  }

  /// An agent of a folder gives a record with its description and its body.
  @Test func anAgentOfAFolderGivesARecord() async throws {
    let fixture = try SettingsGraphFixture(label: "library-agent")
    try AgentFolderFixture.write(
      id: Self.agentID, under: try Self.projectRoot(of: .agents, in: fixture),
      description: "Keeps the zoo.", body: "Feed each animal.")
    let catalog = Self.catalog(of: fixture)

    let record = try await catalog.record(
      LibraryRecordID(
        domain: LibraryDomain(kind: .agent, level: .folder(fixture.firstDirectory)),
        name: Self.agentID))

    #expect(record?.description == "Keeps the zoo.")
    #expect(record?.body?.contains("Feed each animal.") == true)
  }

  /// An MCP server record holds the name, the state and the kind of the transport, and no
  /// command, no argument and no environment value.
  @Test func anMCPServerRecordHoldsNoSecret() async throws {
    let fixture = try SettingsGraphFixture(label: "library-mcp")
    try ConfigFileFixture.write(
      """
      tools:
        mcp:
          - name: zoo
            command: \(Self.secretCommand)
            args: ["--key", "\(Self.secretValue)"]
            env:
              TOKEN: \(Self.secretValue)
      """, in: try fixture.sessionRoot(of: fixture.firstDirectory))
    let catalog = Self.catalog(of: fixture)

    let records = try await catalog.records(
      of: LibraryDomain(kind: .mcpServer, level: .folder(fixture.firstDirectory)))

    #expect(records.map(\.id.name) == ["zoo"])
    #expect(records.first?.transportKind == "stdio")
    let text = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    #expect(!text.contains(Self.secretCommand))
    #expect(!text.contains(Self.secretValue))
  }

  /// A folder that the `readableFolder` rule refuses gives no record, and no domain of it has a
  /// stamp.
  @Test func aFolderThatTheRuleRefusesGivesNoRecord() async throws {
    let fixture = try SettingsGraphFixture(label: "library-refused")
    try writeSkillFixture(
      id: Self.skillID, markdown: Self.skillMarkdown(Self.skillID),
      under: try Self.projectRoot(of: .skills, in: fixture))
    let catalog = Self.catalog(of: fixture, readable: { _ in false })

    let records = try await catalog.records(
      of: LibraryDomain(kind: .skill, level: .folder(fixture.firstDirectory)))

    #expect(records.isEmpty)
    #expect(try await catalog.stamps().keys.allSatisfy { $0.level == .user })
  }

  /// A new skill in a folder that the host read gives a change with each record of the domain.
  @Test func aNewSkillGivesAChange() async throws {
    let fixture = try SettingsGraphFixture(label: "library-change")
    let root = try Self.projectRoot(of: .skills, in: fixture)
    try writeSkillFixture(id: Self.skillID, markdown: Self.skillMarkdown(Self.skillID), under: root)
    let catalog = Self.catalog(of: fixture)
    let domain = LibraryDomain(kind: .skill, level: .folder(fixture.firstDirectory))
    _ = try await catalog.records(of: domain)
    let changes = catalog.changes()

    try writeSkillFixture(id: "lion-feeding", markdown: Self.skillMarkdown("lion-feeding"), under: root)

    var names: [String] = []
    for await change in changes {
      if case .changed(domain, let records) = change {
        names = records.map(\.id.name)
        if names.count == 2 { break }
      }
    }
    #expect(names == ["lion-feeding", Self.skillID])
  }
}
