import Foundation
import FoundationModelsACPAgent
import FoundationModelsRouter
import Testing

/// The append-only `sessions.jsonl` index and its rebuild from a directory
/// scan (plan.md §4.1 and §4.3). Every test builds its own throwaway
/// transcripts root under a temp directory.
@Suite struct SessionIndexTests {
    /// A throwaway transcripts root. The OS reclaims the temp directory.
    struct Fixture {
        /// The transcripts root the index operates on.
        let root: URL

        /// The index under test.
        let index: SessionIndex

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SessionIndexTests-\(UUID().uuidString)", isDirectory: true)
            index = SessionIndex(root: root)
        }

        /// The URL of the index file inside the root.
        var indexFile: URL {
            root.appendingPathComponent(SessionIndex.indexFileName)
        }

        /// The raw text of the index file.
        func indexText() throws -> String {
            try String(contentsOf: indexFile, encoding: .utf8)
        }

        /// Overwrites the index file with `text`, creating the root first.
        func writeIndexText(_ text: String) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try text.write(to: indexFile, atomically: true, encoding: .utf8)
        }

        /// Makes a session directory named `name` under the root, with a
        /// `session.json` sidecar when `withSidecar` is set.
        func makeSessionDirectory(named name: String, withSidecar: Bool) throws {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if withSidecar {
                let sidecar = directory.appendingPathComponent("session.json")
                try "{}".write(to: sidecar, atomically: true, encoding: .utf8)
            }
        }
    }

    /// A record with every field filled, updated at a whole second so the
    /// RFC 3339 round trip is exact.
    static func makeRecord(sessionId: String = ULID.generate().ulidString) -> SessionIndexRecord {
        let wholeSecond = Date(timeIntervalSince1970: 1_756_000_000)
        return SessionIndexRecord(
            sessionId: sessionId,
            cwd: "/Users/dev/example",
            title: "Fix the flaky login test",
            updatedAt: wholeSecond,
            additionalDirectories: ["/Users/dev/example/docs", "/Users/dev/shared"])
    }

    // MARK: - Append

    /// Two appended records occupy two lines, each a self-contained JSON
    /// object.
    @Test func twoAppendedRecordsOccupyTwoLines() throws {
        let fixture = Fixture()

        try fixture.index.append(Self.makeRecord())
        try fixture.index.append(Self.makeRecord())

        let lines = try fixture.indexText().split(separator: "\n")
        #expect(lines.count == 2)
    }

    /// A record round-trips its title, its RFC 3339 `updatedAt`, and the
    /// ordered `additionalDirectories` list.
    @Test func appendedRecordRoundTrips() throws {
        let fixture = Fixture()
        let record = Self.makeRecord()

        try fixture.index.append(record)
        let result = try fixture.index.read()

        #expect(result.records == [record])
        #expect(result.warnings.isEmpty)
    }

    /// The serialized record carries exactly the five index fields, with
    /// `updatedAt` as an RFC 3339 string — and never an `mcpServers` field.
    @Test func serializedRecordCarriesExactlyTheIndexFields() throws {
        let fixture = Fixture()

        try fixture.index.append(Self.makeRecord())

        let line = try fixture.indexText().split(separator: "\n")[0]
        let object =
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
        let expectedKeys: Set<String> = [
            "sessionId", "cwd", "title", "updatedAt", "additionalDirectories",
        ]
        #expect(Set(object.keys) == expectedKeys)
        #expect(object["updatedAt"] as? String == "2025-08-24T01:46:40Z")
    }

    /// A missing index file reads as an empty result, not an error.
    @Test func missingIndexFileReadsAsEmpty() throws {
        let fixture = Fixture()

        let result = try fixture.index.read()

        #expect(result.records.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    // MARK: - .gitattributes

    /// The first append materializes `.gitattributes` with both rules:
    /// `linguist-generated=true` on everything under the root, and
    /// `merge=union` on `sessions.jsonl`.
    @Test func firstAppendMaterializesGitattributes() throws {
        let fixture = Fixture()

        try fixture.index.append(Self.makeRecord())

        let attributesFile = fixture.root.appendingPathComponent(".gitattributes")
        let contents = try String(contentsOf: attributesFile, encoding: .utf8)
        #expect(contents.contains("linguist-generated=true"))
        #expect(contents.contains("sessions.jsonl merge=union"))
    }

    /// A later append never rewrites an existing `.gitattributes`, so a
    /// user's edit survives.
    @Test func laterAppendKeepsAnEditedGitattributes() throws {
        let fixture = Fixture()
        try fixture.index.append(Self.makeRecord())
        let attributesFile = fixture.root.appendingPathComponent(".gitattributes")
        let edited = "# edited by hand\n"
        try edited.write(to: attributesFile, atomically: true, encoding: .utf8)

        try fixture.index.append(Self.makeRecord())

        let contents = try String(contentsOf: attributesFile, encoding: .utf8)
        #expect(contents == edited)
    }

    // MARK: - Damage

    /// A torn final line — the crash artifact §4.1 describes — is dropped
    /// with a warning, and every earlier record still reads.
    @Test func tornFinalLineIsDroppedWithAWarning() throws {
        let fixture = Fixture()
        let record = Self.makeRecord()
        try fixture.index.append(record)
        let torn = try fixture.indexText() + "{\"sessionId\":\"01ARZ3ND"
        try fixture.writeIndexText(torn)

        let result = try fixture.index.read()

        #expect(result.records == [record])
        #expect(result.warnings == [.tornFinalLine])
    }

    /// A corrupt line before the final one is real damage, not a crash
    /// artifact: the read throws and names the line.
    @Test func corruptEarlierLineThrows() throws {
        let fixture = Fixture()
        let record = Self.makeRecord()
        try fixture.index.append(record)
        let corrupted = "not json at all\n" + (try fixture.indexText())
        try fixture.writeIndexText(corrupted)

        #expect(throws: SessionIndexError.corruptLine(number: 1)) {
            try fixture.index.read()
        }
    }

    // MARK: - Rebuild

    /// The rebuild scans the session directories: a directory counts only
    /// when its name parses as a ULID and it holds `session.json`.
    @Test func rebuildScansOnlyUlidDirectoriesWithASidecar() throws {
        let fixture = Fixture()
        let goodId = ULID.generate().ulidString
        try fixture.makeSessionDirectory(named: goodId, withSidecar: true)
        try fixture.makeSessionDirectory(named: ULID.generate().ulidString, withSidecar: false)
        try fixture.makeSessionDirectory(named: "not-a-ulid", withSidecar: true)
        let cwd = URL(fileURLWithPath: "/Users/dev/example", isDirectory: true)

        let records = try fixture.index.rebuild(cwd: cwd)

        #expect(records.map(\.sessionId) == [goodId])
        #expect(records.map(\.cwd) == ["/Users/dev/example"])
    }

    /// The rebuild replaces a damaged index, so a later read succeeds.
    @Test func rebuildReplacesADamagedIndex() throws {
        let fixture = Fixture()
        let goodId = ULID.generate().ulidString
        try fixture.makeSessionDirectory(named: goodId, withSidecar: true)
        try fixture.writeIndexText("garbage\nmore garbage\n")
        let cwd = URL(fileURLWithPath: "/Users/dev/example", isDirectory: true)

        let rebuilt = try fixture.index.rebuild(cwd: cwd)
        let result = try fixture.index.read()

        #expect(result.records == rebuilt)
        #expect(result.records.map(\.sessionId) == [goodId])
    }
}
