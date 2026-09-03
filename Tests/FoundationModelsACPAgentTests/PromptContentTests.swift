import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMultitool
import MCP
import Testing

@testable import FoundationModelsACPAgent

/// The prompt-content policy (plan.md §12, §5): the honest capability
/// advertisement, the resource-link resolution through the files verb,
/// the embedded-context fold, and the MCP content passthrough map.
@Suite struct PromptContentTests {
    // MARK: - Constants

    /// The text of the file inside the session root.
    private static let insideFileContent = "line one inside the root\nline two inside the root"

    /// The text of the file outside the root set. No model prompt may
    /// carry it.
    private static let outsideFileContent = "the secret text outside the root set"

    /// The name of each linked temporary file.
    private static let linkedFileName = "linked.txt"

    /// An `http://` URI a prompt can carry. The agent must not fetch it.
    private static let httpURI = "http://example.com/page"

    /// A URI of a text resource that a prompt embeds.
    private static let embeddedURI = "mem://embedded/one"

    // MARK: - Harness

    /// Makes a files-backed read verb over `root`, through the same
    /// public registry door the session composition uses.
    ///
    /// - Parameter root: The one confinement root.
    /// - Returns: The mounted `tools.files.read` verb.
    /// - Throws: Whatever the registry build throws.
    private static func makeReadVerb(root: URL) throws -> any FoundationModels.Tool {
        let builder = MultiTool.Builder()
        builder.withFiles(root: root)
        let registry = try builder.buildRegistry()
        return try #require(registry.tools[ToolCatalog.filesReadVerbPath])
    }

    /// Makes a resolver whose read verb is confined to `root`.
    ///
    /// - Parameter root: The one confinement root.
    /// - Returns: The resolver under test.
    /// - Throws: Whatever the registry build throws.
    private static func makeResolver(root: URL) throws -> ResourceLinkResolver {
        ResourceLinkResolver(readVerb: try makeReadVerb(root: root))
    }

    /// Writes `content` to a fresh file in `directory` and returns its URL.
    ///
    /// - Parameters:
    ///   - directory: The directory that holds the file.
    ///   - content: The text to write.
    /// - Returns: The file URL.
    /// - Throws: Whatever the write throws.
    private static func makeFile(in directory: URL, content: String) throws -> URL {
        let file = directory.appendingPathComponent(linkedFileName)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The `file://` URI of a file URL.
    ///
    /// - Parameter url: The file URL.
    /// - Returns: The URI string.
    private static func fileURI(of url: URL) -> String {
        url.absoluteString
    }

    /// The prompt request over `blocks`.
    ///
    /// - Parameters:
    ///   - sessionId: The session to prompt.
    ///   - blocks: The content blocks of the prompt.
    /// - Returns: The request.
    private static func makePromptRequest(
        sessionId: SessionId, blocks: [ContentBlock]
    ) -> PromptRequest {
        PromptRequest(prompt: blocks, sessionId: sessionId)
    }

    /// Wires a recorded scripted fixture, prompts it with `blocks`, and
    /// returns the one model prompt the scripted backend received.
    ///
    /// - Parameter blocks: The content blocks of the prompt.
    /// - Returns: The recorded model prompt.
    /// - Throws: Whatever the fixture or the turn throws.
    private static func recordedModelPrompt(blocks: [ContentBlock]) async throws -> String {
        let recorder = PromptRecorder()
        let fixture = try await ScriptedTurnFixture.make(
            loader: makeScriptedModelLoader(script: [.endTurn], recorder: recorder),
            label: "PromptContentTests")
        _ = try await fixture.harness.connection.prompt(
            makePromptRequest(sessionId: fixture.sessionId, blocks: blocks))
        _ = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()
        return try #require(await recorder.prompts.first)
    }

    // MARK: - The honest advertisement (plan.md §5, §12)

    /// The advertisement and the consumption agree on every content
    /// kind. This is the two-sided honesty test: a kind is advertised
    /// exactly when the prompt path can act on it.
    @Test func theAdvertisementAndTheConsumptionAgreeOnEveryKind() {
        for kind in PromptContentKind.allCases {
            #expect(PromptContent.advertises(kind) == PromptContent.consumes(kind))
        }
    }

    /// Text is the unconditional MUST: always advertised, always
    /// consumed. `resource_link` is not capability-gated and is always
    /// consumed as well.
    @Test func textAndResourceLinksAreTheUngatedBaseline() {
        #expect(PromptContent.advertises(.text))
        #expect(PromptContent.consumes(.text))
        #expect(PromptContent.advertises(.resourceLink))
        #expect(PromptContent.consumes(.resourceLink))
    }

    /// The day-one advertisement carries `embeddedContext` only: no
    /// image and no audio, because the roster cannot act on them.
    @Test func theDayOneAdvertisementCarriesEmbeddedContextOnly() {
        #expect(PromptContent.advertisedCapabilities.embeddedContext != nil)
        #expect(PromptContent.advertisedCapabilities.image == nil)
        #expect(PromptContent.advertisedCapabilities.audio == nil)
    }

    /// The `initialize` advertisement is the one `PromptContent`
    /// advertisement, so the wire cannot drift from the consumption.
    @Test func theInitializeAdvertisementIsThePromptContentAdvertisement() throws {
        let session = try #require(RoutedACPAgent.advertisedCapabilities.session)
        #expect(session.prompt == PromptContent.advertisedCapabilities)
    }

    // MARK: - The model-prompt fold (plan.md §12)

    /// Text blocks and embedded text resources fold into the model
    /// prompt in block order.
    @Test func textAndEmbeddedResourcesFoldIntoTheModelPrompt() async {
        let blocks: [ContentBlock] = [
            .text(TextContent(text: "alpha")),
            .resource(
                EmbeddedResource(
                    resource: .object([
                        "text": .string("beta"),
                        "uri": .string(Self.embeddedURI),
                    ]))),
            .text(TextContent(text: "gamma")),
        ]

        let prompt = await PromptContent.modelPrompt(
            from: blocks, resolver: ResourceLinkResolver(readVerb: nil))

        #expect(prompt == "alpha\nbeta\ngamma")
    }

    /// A UTF-8 blob resource folds as its decoded text.
    @Test func aUTF8BlobResourceFoldsAsItsDecodedText() async {
        let blob = Data("blob text".utf8).base64EncodedString()
        let blocks: [ContentBlock] = [
            .resource(
                EmbeddedResource(
                    resource: .object([
                        "blob": .string(blob),
                        "uri": .string(Self.embeddedURI),
                    ])))
        ]

        let prompt = await PromptContent.modelPrompt(
            from: blocks, resolver: ResourceLinkResolver(readVerb: nil))

        #expect(prompt == "blob text")
    }

    /// A blob that is not UTF-8 text folds as a reasoned note that
    /// names the resource, never as garbage bytes.
    @Test func aBinaryBlobResourceFoldsAsAReasonedNote() async {
        let binaryBytes: [UInt8] = [0xFF, 0xFE, 0x00]
        let blob = Data(binaryBytes).base64EncodedString()
        let blocks: [ContentBlock] = [
            .resource(
                EmbeddedResource(
                    resource: .object([
                        "blob": .string(blob),
                        "uri": .string(Self.embeddedURI),
                    ])))
        ]

        let prompt = await PromptContent.modelPrompt(
            from: blocks, resolver: ResourceLinkResolver(readVerb: nil))

        #expect(prompt.contains(Self.embeddedURI))
        #expect(prompt.contains("not UTF-8"))
    }

    /// A resource payload that carries neither text nor blob folds as a
    /// reasoned note.
    @Test func anEmptyResourcePayloadFoldsAsAReasonedNote() async {
        let blocks: [ContentBlock] = [
            .resource(EmbeddedResource(resource: .object(["uri": .string(Self.embeddedURI)])))
        ]

        let prompt = await PromptContent.modelPrompt(
            from: blocks, resolver: ResourceLinkResolver(readVerb: nil))

        #expect(!prompt.isEmpty)
    }

    /// Image and audio blocks fold nothing, because the roster cannot
    /// act on them and the advertisement says so.
    @Test func imageAndAudioBlocksFoldNothing() async {
        let payload = Data("media".utf8).base64EncodedString()
        let blocks: [ContentBlock] = [
            .text(TextContent(text: "only this")),
            .image(ImageContent(data: payload, mimeType: MediaType(rawValue: "image/png"))),
            .audio(AudioContent(data: payload, mimeType: MediaType(rawValue: "audio/wav"))),
        ]

        let prompt = await PromptContent.modelPrompt(
            from: blocks, resolver: ResourceLinkResolver(readVerb: nil))

        #expect(prompt == "only this")
    }

    /// `Annotations` on an embedded resource are ignored on input: the
    /// resource still folds as its text.
    @Test func annotationsOnAnEmbeddedResourceAreIgnoredOnInput() async {
        let blocks: [ContentBlock] = [
            .resource(
                EmbeddedResource(
                    resource: .object([
                        "text": .string("annotated"),
                        "uri": .string(Self.embeddedURI),
                    ]),
                    annotations: FoundationModelsACP.Annotations(
                        audience: [.user], priority: 1)))
        ]

        let prompt = await PromptContent.modelPrompt(
            from: blocks, resolver: ResourceLinkResolver(readVerb: nil))

        #expect(prompt == "annotated")
    }

    // MARK: - The resource-link resolution (plan.md §12)

    /// A `file://` URI inside the root resolves to the file's text.
    @Test func aFileURIInsideTheRootResolvesToTheFileText() async throws {
        let root = makeResolvedDirectory(label: "PromptContentTests-root")
        let file = try Self.makeFile(in: root, content: Self.insideFileContent)
        let resolver = try Self.makeResolver(root: root)

        let resolved = await resolver.resolve(uri: Self.fileURI(of: file))

        #expect(resolved == Self.insideFileContent)
    }

    /// A `file://` URI outside the root set comes back refused, with
    /// the files verb's own in-band correction as the reason, and the
    /// file's text never appears.
    @Test func aFileURIOutsideTheRootSetIsRefusedThroughTheCorrection() async throws {
        let root = makeResolvedDirectory(label: "PromptContentTests-root")
        let outside = makeResolvedDirectory(label: "PromptContentTests-outside")
        let file = try Self.makeFile(in: outside, content: Self.outsideFileContent)
        let resolver = try Self.makeResolver(root: root)

        let resolved = await resolver.resolve(uri: Self.fileURI(of: file))

        #expect(resolved.contains("was not read"))
        #expect(!resolved.contains(Self.outsideFileContent))
    }

    /// An `http://` URI is refused with a reason. The agent never
    /// fetches it.
    @Test func anHTTPURIIsRefusedWithAReason() async throws {
        let root = makeResolvedDirectory(label: "PromptContentTests-root")
        let resolver = try Self.makeResolver(root: root)

        let resolved = await resolver.resolve(uri: Self.httpURI)

        #expect(resolved.contains("was not read"))
        #expect(resolved.contains("file://"))
    }

    /// A URI that does not parse is refused with a reason.
    @Test func aMalformedURIIsRefusedWithAReason() async throws {
        let root = makeResolvedDirectory(label: "PromptContentTests-root")
        let resolver = try Self.makeResolver(root: root)

        let resolved = await resolver.resolve(uri: "not a uri at all")

        #expect(resolved.contains("was not read"))
    }

    /// A session with no mounted files verb refuses the link with a
    /// reason instead of reading anything.
    @Test func aMissingFilesVerbRefusesWithAReason() async {
        let resolver = ResourceLinkResolver(readVerb: nil)

        let resolved = await resolver.resolve(uri: "file:///tmp/anything.txt")

        #expect(resolved.contains("was not read"))
    }

    // MARK: - The MCP passthrough map (plan.md §12)

    /// MCP text content maps to the ACP text block, type to type.
    @Test func mcpTextContentMapsTypeToType() throws {
        let block = PromptContent.contentBlock(
            from: .text(text: "hello", annotations: nil, _meta: nil))

        guard case .text(let content) = block else {
            Issue.record("expected a text block, got \(block)")
            return
        }
        #expect(content.text == "hello")
    }

    /// MCP image content maps to the ACP image block, type to type.
    @Test func mcpImageContentMapsTypeToType() throws {
        let block = PromptContent.contentBlock(
            from: .image(data: "aW1n", mimeType: "image/png", annotations: nil, _meta: nil))

        guard case .image(let content) = block else {
            Issue.record("expected an image block, got \(block)")
            return
        }
        #expect(content.data == "aW1n")
        #expect(content.mimeType == MediaType(rawValue: "image/png"))
    }

    /// MCP audio content maps to the ACP audio block, type to type.
    @Test func mcpAudioContentMapsTypeToType() throws {
        let block = PromptContent.contentBlock(
            from: .audio(data: "YXVk", mimeType: "audio/wav", annotations: nil, _meta: nil))

        guard case .audio(let content) = block else {
            Issue.record("expected an audio block, got \(block)")
            return
        }
        #expect(content.data == "YXVk")
        #expect(content.mimeType == MediaType(rawValue: "audio/wav"))
    }

    /// An MCP resource link maps to the ACP resource-link block with
    /// every field carried.
    @Test func mcpResourceLinkContentMapsTypeToType() throws {
        let block = PromptContent.contentBlock(
            from: .resourceLink(
                uri: "file:///tmp/a.txt", name: "a", title: "A", description: "the a file",
                mimeType: "text/plain"))

        guard case .resourceLink(let link) = block else {
            Issue.record("expected a resource-link block, got \(block)")
            return
        }
        #expect(link.uri == "file:///tmp/a.txt")
        #expect(link.name == "a")
        #expect(link.title == "A")
        #expect(link.description == "the a file")
        #expect(link.mimeType == MediaType(rawValue: "text/plain"))
    }

    /// An MCP embedded text resource maps to the ACP embedded-resource
    /// block whose payload carries the text and the URI.
    @Test func mcpEmbeddedTextResourceMapsTypeToType() throws {
        let block = PromptContent.contentBlock(
            from: .resource(
                resource: .text("body", uri: Self.embeddedURI, mimeType: "text/plain")))

        guard case .resource(let embedded) = block,
            case .object(let members) = embedded.resource
        else {
            Issue.record("expected an embedded resource object, got \(block)")
            return
        }
        #expect(members["text"] == .string("body"))
        #expect(members["uri"] == .string(Self.embeddedURI))
        #expect(members["mimeType"] == .string("text/plain"))
    }

    /// An MCP embedded blob resource maps to the ACP embedded-resource
    /// block whose payload carries the blob and the URI.
    @Test func mcpEmbeddedBlobResourceMapsTypeToType() throws {
        let bytes = Data("binary".utf8)
        let block = PromptContent.contentBlock(
            from: .resource(resource: .binary(bytes, uri: Self.embeddedURI)))

        guard case .resource(let embedded) = block,
            case .object(let members) = embedded.resource
        else {
            Issue.record("expected an embedded resource object, got \(block)")
            return
        }
        #expect(members["blob"] == .string(bytes.base64EncodedString()))
        #expect(members["uri"] == .string(Self.embeddedURI))
    }

    /// MCP annotations map across the passthrough: the audience roles,
    /// the priority, and the last-modified stamp all carry.
    @Test func mcpAnnotationsMapAcrossThePassthrough() throws {
        let block = PromptContent.contentBlock(
            from: .text(
                text: "noted",
                annotations: MCP.Resource.Annotations(
                    audience: [.user, .assistant],
                    priority: 0.5,
                    lastModified: "2025-01-12T15:00:58Z"),
                _meta: nil))

        guard case .text(let content) = block else {
            Issue.record("expected a text block, got \(block)")
            return
        }
        let annotations = try #require(content.annotations)
        #expect(annotations.audience == [.user, .assistant])
        #expect(annotations.priority == 0.5)
        #expect(annotations.lastModified == "2025-01-12T15:00:58Z")
    }

    /// The tool-call content map wraps each MCP block as one
    /// `tool_call_update` content item, in order.
    @Test func theToolCallContentMapWrapsEachBlockInOrder() throws {
        let items = PromptContent.toolCallContent(from: [
            .text(text: "first", annotations: nil, _meta: nil),
            .text(text: "second", annotations: nil, _meta: nil),
        ])

        #expect(items.count == 2)
        guard case .content(let first) = items[0], case .text(let text) = first.content else {
            Issue.record("expected a wrapped text item, got \(items)")
            return
        }
        #expect(text.text == "first")
    }

    // MARK: - The turn on the harness (plan.md §12, §20.1)

    /// A prompt with a `resource_link` to a file inside the cwd puts
    /// the file's text into the model prompt the scripted backend
    /// receives.
    @Test(.timeLimit(.minutes(1)))
    func aResourceLinkInsideTheCwdReachesTheScriptedBackend() async throws {
        let recorder = PromptRecorder()
        let fixture = try await ScriptedTurnFixture.make(
            loader: makeScriptedModelLoader(script: [.endTurn], recorder: recorder),
            label: "PromptContentTests")
        let file = try Self.makeFile(in: fixture.cwd, content: Self.insideFileContent)

        _ = try await fixture.harness.connection.prompt(
            Self.makePromptRequest(
                sessionId: fixture.sessionId,
                blocks: [
                    .text(TextContent(text: "read the link")),
                    .resourceLink(ResourceLink(name: Self.linkedFileName, uri: Self.fileURI(of: file))),
                ]))
        _ = try await ScriptedTurnFixture.waitForIdle(fixture.collector)
        await fixture.close()

        let prompt = try #require(await recorder.prompts.first)
        #expect(prompt.contains("read the link"))
        #expect(prompt.contains(Self.insideFileContent))
    }

    /// A `resource_link` to a path outside the root set is refused in
    /// the model prompt with a reason, and the file's text never
    /// reaches the backend.
    @Test(.timeLimit(.minutes(1)))
    func anOutOfRootResourceLinkIsRefusedInTheModelPrompt() async throws {
        let outside = makeResolvedDirectory(label: "PromptContentTests-outside")
        let file = try Self.makeFile(in: outside, content: Self.outsideFileContent)

        let prompt = try await Self.recordedModelPrompt(blocks: [
            .resourceLink(ResourceLink(name: Self.linkedFileName, uri: Self.fileURI(of: file)))
        ])

        #expect(prompt.contains("was not read"))
        #expect(!prompt.contains(Self.outsideFileContent))
    }

    /// A `resource_link` to an `http://` URI is refused in the model
    /// prompt with a reason. Nothing is fetched.
    @Test(.timeLimit(.minutes(1)))
    func anHTTPResourceLinkIsRefusedInTheModelPrompt() async throws {
        let prompt = try await Self.recordedModelPrompt(blocks: [
            .resourceLink(ResourceLink(name: "page", uri: Self.httpURI))
        ])

        #expect(prompt.contains("was not read"))
        #expect(prompt.contains("file://"))
    }
}
