import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import Testing

@testable import FoundationModelsACPAgent

/// The display events of a tool on the wire: a tool posts output or
/// metadata for the client through `ToolContext.post(display:)`, Router sends
/// it live as `SessionEvent.toolDisplay`, and the agent sends it to the
/// client as the v2 prompt-lifecycle shapes.
///
/// - A content chunk goes as one `tool_call_content_chunk`.
/// - A content replace goes as a `tool_call_update` that replaces the
///   content.
/// - A metadata event goes as a `tool_call_update` patch with `title`,
///   `kind`, `locations` and `rawInput`. A `nil` field is absent from the
///   patch, because a `null` clears the field on the client.
/// - The settlement of the run stays the last update of the tool call.
///
/// Each test reads the updates through the JSON codec of the transport.
@Suite struct ToolDisplayProjectionTests {
    // MARK: - Constants

    /// The completion token of the run: the correlation id of each display
    /// event of the run, and its tool call id.
    private static let runToken = "01DISPLAYRUNTOKEN000000000"

    /// The tool that posts the display events.
    private static let toolName = "files"

    /// The op of the run that posts the display events.
    private static let opName = "edit file"

    /// The text of the first output part.
    private static let firstPart = "read 812 lines"

    /// The text of the second output part.
    private static let secondPart = "wrote 3 lines"

    /// The title that the tool gives to its call.
    private static let toolTitle = "Edit /repo/notes.txt"

    /// The absolute file that the tool changes.
    private static let changedPath = "/repo/notes.txt"

    /// The line of the change in ``changedPath``.
    private static let changedLine = 12

    /// The input of the call, as a JSON text.
    private static let rawInputJSON = #"{"path":"/repo/notes.txt"}"#

    /// The text of a file before the change.
    private static let oldFileText = "alpha\nbeta\n"

    /// The text of a file after the change.
    private static let newFileText = "alpha\ngamma\n"

    // MARK: - Fixtures

    /// A display event of the run.
    ///
    /// - Parameter kind: What the event tells the client.
    /// - Returns: The event.
    private static func display(_ kind: ToolDisplayEvent.Kind) -> SessionEvent {
        .toolDisplay(ToolDisplayEvent(tool: toolName, op: opName, correlationID: runToken, kind: kind))
    }

    /// The terminal event of the run.
    ///
    /// - Parameter outcome: How the run ended.
    /// - Returns: The event.
    private static func settlement(_ outcome: OperationOutcome) -> SessionEvent {
        .runSettled(
            OperationEvent(
                tool: toolName, op: opName, correlationID: runToken, kind: .completed, detail: "{}",
                outcome: outcome))
    }

    /// The wire objects of the updates of the tool call of the run, in send
    /// order: each update that names ``runToken`` as its `toolCallId`.
    ///
    /// - Parameter updates: The sent updates.
    /// - Returns: The wire objects.
    /// - Throws: The encoding error of an update.
    private static func runWireUpdates(
        in updates: [SessionUpdate]
    ) throws -> [[String: FoundationModelsACP.JSONValue]] {
        try updates.compactMap { try wireObject(of: $0) }.filter {
            jsonString(of: $0["toolCallId"]) == runToken
        }
    }

    /// The one wire object of the tool call of the run that `events` give.
    ///
    /// - Parameter events: The events of the prompt.
    /// - Returns: The wire object, or `nil` when the run has not exactly one
    ///   update.
    /// - Throws: The encoding error of an update.
    private static func onlyRunWireUpdate(
        of events: [SessionEvent]
    ) async throws -> [String: FoundationModelsACP.JSONValue]? {
        let updates = try runWireUpdates(in: await SyntheticPrompt.sentUpdates(events))
        return updates.count == 1 ? updates.first : nil
    }

    /// The items of a JSON array.
    ///
    /// - Parameter value: The JSON value to read, or `nil`.
    /// - Returns: The items, or `nil` when the value is not an array.
    private static func jsonArray(
        of value: FoundationModelsACP.JSONValue?
    ) -> [FoundationModelsACP.JSONValue]? {
        guard case .array(let items) = value else { return nil }
        return items
    }

    /// The text of a wire content item of the `content` type.
    ///
    /// - Parameter item: The wire content item, or `nil`.
    /// - Returns: The text, or `nil` when the item is something else.
    private static func contentText(of item: FoundationModelsACP.JSONValue?) -> String? {
        guard let fields = jsonObject(of: item), jsonString(of: fields["type"]) == "content" else {
            return nil
        }
        return jsonString(of: jsonObject(of: fields["content"])?["text"])
    }

    // MARK: - The content chunk

    /// A content chunk gives one `tool_call_content_chunk` on the wire. It
    /// keys on the run token and carries the one content item.
    @Test func aContentChunkGivesOneToolCallContentChunk() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [Self.display(.contentChunk(.text(Self.firstPart)))]))

        #expect(jsonString(of: update["sessionUpdate"]) == "tool_call_content_chunk")
        #expect(Self.contentText(of: update["content"]) == Self.firstPart)
    }

    /// A JSON content part rides as text: the projection does not read a
    /// document that the tool owns.
    @Test func aJSONContentChunkRidesAsText() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [Self.display(.contentChunk(.json(Self.rawInputJSON)))]))

        #expect(Self.contentText(of: update["content"]) == Self.rawInputJSON)
    }

    /// A diff part of a changed file rides as a `diff` item: one `modify`
    /// change at the absolute path, and a git patch that removes the old
    /// lines and adds the new lines.
    @Test func aDiffChunkGivesAModifyChangeAndAGitPatch() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(
                    .contentChunk(
                        .diff(path: Self.changedPath, oldText: Self.oldFileText, newText: Self.newFileText)))
            ]))
        let diff = try #require(jsonObject(of: update["content"]))
        let change = try #require(jsonObject(of: Self.jsonArray(of: diff["changes"])?.first))
        let patch = try #require(jsonObject(of: diff["patch"]))

        #expect(jsonString(of: diff["type"]) == "diff")
        #expect(jsonString(of: change["operation"]) == "modify")
        #expect(jsonString(of: change["path"]) == Self.changedPath)
        #expect(jsonString(of: patch["format"]) == "git_patch")
        #expect(
            jsonString(of: patch["text"]) == """
                diff --git \(Self.changedPath) \(Self.changedPath)
                --- \(Self.changedPath)
                +++ \(Self.changedPath)
                @@ -1,2 +1,2 @@
                -alpha
                -beta
                +alpha
                +gamma

                """)
    }

    /// A diff part with no old text is a new file: one `add` change, and a
    /// git patch from `/dev/null`.
    @Test func aDiffChunkWithNoOldTextGivesAnAddChange() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(.contentChunk(.diff(path: Self.changedPath, oldText: nil, newText: "gamma")))
            ]))
        let diff = try #require(jsonObject(of: update["content"]))
        let change = try #require(jsonObject(of: Self.jsonArray(of: diff["changes"])?.first))
        let patch = try #require(jsonObject(of: diff["patch"]))

        #expect(jsonString(of: change["operation"]) == "add")
        #expect(
            jsonString(of: patch["text"]) == """
                diff --git \(Self.changedPath) \(Self.changedPath)
                new file mode 100644
                --- /dev/null
                +++ \(Self.changedPath)
                @@ -0,0 +1 @@
                +gamma
                \\ No newline at end of file

                """)
    }

    /// A diff part that keeps the text has no patch to report: the `diff`
    /// item names the change and omits `patch`, because the patch is
    /// optional on the wire and an empty patch text is not a git patch.
    @Test func aDiffChunkThatKeepsTheTextOmitsThePatch() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(
                    .contentChunk(
                        .diff(path: Self.changedPath, oldText: Self.oldFileText, newText: Self.oldFileText)))
            ]))
        let diff = try #require(jsonObject(of: update["content"]))

        #expect(jsonString(of: diff["type"]) == "diff")
        #expect(diff["patch"] == nil)
    }

    /// A diff part whose path is not absolute cannot ride as a `diff` item,
    /// because the wire requires an absolute path. It rides as a text item
    /// that holds the same patch, so the client still shows the change.
    @Test func aDiffChunkWithARelativePathRidesAsPatchText() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(.contentChunk(.diff(path: "notes.txt", oldText: "beta\n", newText: "gamma\n")))
            ]))

        let text = try #require(Self.contentText(of: update["content"]))
        #expect(text.hasPrefix("diff --git notes.txt notes.txt\n"))
        #expect(text.hasSuffix("-beta\n+gamma\n"))
    }

    // MARK: - The content replace

    /// A content replace gives a `tool_call_update` on the run token that
    /// replaces the content with the new parts, in order.
    @Test func aContentReplaceGivesAToolCallUpdateWithTheNewContent() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(.contentReplace([.text(Self.firstPart), .text(Self.secondPart)]))
            ]))

        #expect(jsonString(of: update["sessionUpdate"]) == "tool_call_update")
        let items = try #require(Self.jsonArray(of: update["content"]))
        #expect(items.map(Self.contentText(of:)) == [Self.firstPart, Self.secondPart])
    }

    // MARK: - The metadata patch

    /// A metadata event gives a `tool_call_update` patch with `title`,
    /// `kind`, `locations` and `rawInput`.
    @Test func aMetadataEventGivesAPatchWithTitleKindLocationsAndRawInput() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(
                    .metadata(
                        title: Self.toolTitle, kind: .switchMode,
                        locations: [ToolDisplayEvent.Location(path: Self.changedPath, line: Self.changedLine)],
                        rawInput: Self.rawInputJSON))
            ]))

        #expect(jsonString(of: update["sessionUpdate"]) == "tool_call_update")
        #expect(jsonString(of: update["title"]) == Self.toolTitle)
        #expect(jsonString(of: update["kind"]) == "switch_mode")
        let location = try #require(jsonObject(of: Self.jsonArray(of: update["locations"])?.first))
        #expect(jsonString(of: location["path"]) == Self.changedPath)
        #expect(location["line"] == .number(Double(Self.changedLine)))
        #expect(jsonString(of: jsonObject(of: update["rawInput"])?["path"]) == Self.changedPath)
    }

    /// A `nil` metadata field means "no change": the patch omits the field,
    /// and never sends `null`, because a `null` clears the field on the
    /// client. `ToolContext.update(title:kind:locations:)` gives such an
    /// event, with `rawInput` always `nil`.
    @Test func aNilMetadataFieldIsAbsentFromThePatch() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(.metadata(title: Self.toolTitle, kind: nil, locations: nil, rawInput: nil))
            ]))

        #expect(jsonString(of: update["title"]) == Self.toolTitle)
        #expect(update["kind"] == nil)
        #expect(update["locations"] == nil)
        #expect(update["rawInput"] == nil)
    }

    /// A location whose path is not absolute cannot ride on the wire. The
    /// patch keeps the other locations, and it never invents a path.
    @Test func aRelativeMetadataLocationIsDropped() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(
                    .metadata(
                        title: nil, kind: nil,
                        locations: [
                            ToolDisplayEvent.Location(path: "notes.txt"),
                            ToolDisplayEvent.Location(path: Self.changedPath),
                        ],
                        rawInput: nil))
            ]))

        let locations = try #require(Self.jsonArray(of: update["locations"]))
        #expect(locations.map { jsonString(of: jsonObject(of: $0)?["path"]) } == [Self.changedPath])
    }

    /// When no location of the event can ride on the wire, the patch omits
    /// `locations`: an empty array would clear the locations of the call.
    @Test func metadataWithOnlyRelativeLocationsLeavesTheLocationsUnchanged() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(
                    .metadata(
                        title: nil, kind: nil, locations: [ToolDisplayEvent.Location(path: "notes.txt")],
                        rawInput: nil))
            ]))

        #expect(update["locations"] == nil)
    }

    /// An empty location list from the tool clears the locations of the
    /// call: the tool asked for no locations, so the patch sends `[]`.
    @Test func anEmptyMetadataLocationListClearsTheLocations() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(.metadata(title: nil, kind: nil, locations: [], rawInput: nil))
            ]))

        #expect(update["locations"] == .array([]))
    }

    /// A raw input that is not JSON is absent from the patch: the
    /// projection never invents a value from text it cannot parse.
    @Test func aRawInputThatIsNotJSONIsAbsentFromThePatch() async throws {
        let update = try #require(
            try await Self.onlyRunWireUpdate(of: [
                Self.display(.metadata(title: Self.toolTitle, kind: nil, locations: nil, rawInput: "not json"))
            ]))

        #expect(update["rawInput"] == nil)
    }

    // MARK: - The settlement stays last

    /// The settlement replace of a run is the last update of its tool call,
    /// after each display event of the run.
    @Test func theSettlementReplaceIsTheLastUpdateOfTheToolCall() async throws {
        let updates = try Self.runWireUpdates(
            in: await SyntheticPrompt.sentUpdates([
                Self.display(.contentChunk(.text(Self.firstPart))),
                Self.display(.metadata(title: Self.toolTitle, kind: .edit, locations: nil, rawInput: nil)),
                Self.display(.contentReplace([.text(Self.secondPart)])),
                Self.settlement(.timedOut),
            ]))

        #expect(
            updates.map { jsonString(of: $0["sessionUpdate"]) } == [
                "tool_call_content_chunk", "tool_call_update", "tool_call_update", "tool_call_update",
            ])
        let last = try #require(updates.last)
        #expect(jsonString(of: last["status"]) == "failed")
        let items = try #require(Self.jsonArray(of: last["content"]))
        #expect(items.map(Self.contentText(of:)) == ["the run timed out"])
    }

    /// A background run does not withdraw its display events when it
    /// settles inline, in its settle period. Thus a content chunk can come
    /// before an inline settlement: the projection sends the chunk, and the
    /// settlement replace is still the last update of the tool call.
    @Test func aContentChunkBeforeAnInlineSettlementIsSentAndTheSettlementStaysLast() async throws {
        let bytes = Array("done".utf8)
        let stored = ShellRawOutput(
            bytes: bytes, binaryDetected: false, truncated: false, storedByteCount: bytes.count)
        let snapshot = ShellOutputSnapshot(stdout: stored, stderr: stored)
        let updates = try Self.runWireUpdates(
            in: await SyntheticPrompt.sentUpdates(
                [Self.display(.contentChunk(.text(Self.firstPart))), Self.settlement(.succeeded)],
                shellSnapshot: { commandID in commandID == Self.runToken ? snapshot : nil }))

        #expect(
            updates.map { jsonString(of: $0["sessionUpdate"]) } == [
                "tool_call_content_chunk", "tool_call_update",
            ])
        let last = try #require(updates.last)
        #expect(jsonString(of: last["status"]) == "completed")
        let item = try #require(jsonObject(of: Self.jsonArray(of: last["content"])?.first))
        #expect(jsonString(of: item["type"]) == "terminal")
    }
}
