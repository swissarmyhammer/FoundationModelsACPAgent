import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsMultitool
import MCP

/// One prompt-content kind, one for each `ContentBlock` variant this
/// revision names (plan.md §12). The `unknown` wire variant has no kind:
/// the prompt path never folds it.
enum PromptContentKind: CaseIterable, Sendable {
    /// Plain or Markdown text. The unconditional baseline.
    case text

    /// Base64 image data. The roster cannot act on it.
    case image

    /// Base64 audio data. The roster cannot act on it.
    case audio

    /// A link to a resource the agent can read. Not capability-gated.
    case resourceLink

    /// A resource embedded in the message, text or blob.
    case embeddedContext
}

/// The prompt-content policy (plan.md §12, §5): the one place that says
/// which content kinds the composed session consumes, the advertisement
/// `initialize` derives from it, the fold that builds the model prompt,
/// and the MCP tool-result passthrough map.
///
/// The advertisement is honest by construction: it lives beside the
/// consumption code, ``advertises(_:)`` reads it, and a test enumerates
/// every kind and asserts the two sides agree. An absent capability is
/// better than an image that the agent accepts and drops.
enum PromptContent {
    /// The separator between two folded prompt parts.
    private static let partSeparator = "\n"

    /// The member that carries a text resource's payload.
    private static let textMemberName = "text"

    /// The member that carries a blob resource's base64 payload.
    private static let blobMemberName = "blob"

    /// The member that carries a resource's URI.
    private static let uriMemberName = "uri"

    /// The member that carries a resource's MIME type.
    private static let mimeTypeMemberName = "mimeType"

    /// The prompt capabilities this agent advertises at `initialize`
    /// (plan.md §5): `embeddedContext` only, because the fold below can
    /// act on it. Text and resource links are the ungated baseline and
    /// have no marker. No `image` and no `audio`: the roster cannot act
    /// on them on day one.
    static let advertisedCapabilities = PromptCapabilities(
        embeddedContext: PromptEmbeddedContextCapabilities())

    /// Whether the advertisement claims `kind`. Text and resource links
    /// are the ungated baseline and read as always claimed; the gated
    /// kinds read ``advertisedCapabilities`` directly, so this side of
    /// the honesty test cannot drift from the wire.
    ///
    /// - Parameter kind: The content kind to look up.
    /// - Returns: Whether a client may send `kind`.
    static func advertises(_ kind: PromptContentKind) -> Bool {
        switch kind {
        case .text, .resourceLink:
            true
        case .image:
            advertisedCapabilities.image != nil
        case .audio:
            advertisedCapabilities.audio != nil
        case .embeddedContext:
            advertisedCapabilities.embeddedContext != nil
        }
    }

    /// Whether the model prompt folds `kind`. This is the consumption
    /// side of the honesty test: ``foldedPart(of:resolver:)`` drops every
    /// kind this refuses.
    ///
    /// - Parameter kind: The content kind to look up.
    /// - Returns: Whether the fold acts on `kind`.
    static func consumes(_ kind: PromptContentKind) -> Bool {
        switch kind {
        case .text, .resourceLink, .embeddedContext:
            true
        case .image, .audio:
            false
        }
    }

    /// The kind of one wire block, or `nil` for the `unknown` variant.
    ///
    /// - Parameter block: The wire block.
    /// - Returns: The kind, or `nil`.
    static func kind(of block: ContentBlock) -> PromptContentKind? {
        switch block {
        case .text: .text
        case .image: .image
        case .audio: .audio
        case .resourceLink: .resourceLink
        case .resource: .embeddedContext
        case .unknown: nil
        }
    }

    // MARK: - The model-prompt fold (plan.md §12)

    /// Folds the prompt's blocks into the model prompt: text carries
    /// through, each `resource_link` resolves through `resolver`, and
    /// each embedded resource folds as its text. Kinds the session does
    /// not consume fold nothing. The `user_message` echo is unaffected:
    /// it always carries the original blocks verbatim (plan.md §8.3).
    ///
    /// - Parameters:
    ///   - blocks: The request's content blocks, in order.
    ///   - resolver: The resolver of the prompt's resource links.
    /// - Returns: The model prompt.
    static func modelPrompt(
        from blocks: [ContentBlock], resolver: ResourceLinkResolver
    ) async -> String {
        var parts: [String] = []
        for block in blocks {
            if let part = await foldedPart(of: block, resolver: resolver) {
                parts.append(part)
            }
        }
        return parts.joined(separator: partSeparator)
    }

    /// The folded text of one block, or `nil` when the block folds
    /// nothing.
    ///
    /// - Parameters:
    ///   - block: The wire block.
    ///   - resolver: The resolver of a `resource_link` block.
    /// - Returns: The folded text, or `nil`.
    private static func foldedPart(
        of block: ContentBlock, resolver: ResourceLinkResolver
    ) async -> String? {
        guard let kind = kind(of: block), consumes(kind) else { return nil }
        switch block {
        case .text(let content):
            return content.text
        case .resourceLink(let link):
            return await resolver.resolve(uri: link.uri)
        case .resource(let embedded):
            return folded(resource: embedded.resource)
        case .image, .audio, .unknown:
            // The guard on `consumes(_:)` dropped these kinds. The arms
            // keep the switch exhaustive without a `default`.
            return nil
        }
    }

    /// Folds one embedded resource payload (plan.md §12): the text of a
    /// `TextResourceContents`, the decoded blob of a
    /// `BlobResourceContents`, or a reasoned note when neither reads.
    /// `Annotations` are ignored on input.
    ///
    /// The payload is raw wire JSON — `EmbeddedResourceResource` is a
    /// typealias of `JSONValue` — so the fold reads the members by name.
    ///
    /// - Parameter resource: The embedded payload.
    /// - Returns: The folded text, or the note.
    private static func folded(resource: EmbeddedResourceResource) -> String {
        guard case .object(let members) = resource else {
            return "The embedded resource payload is not an object, so nothing is included."
        }
        if case .string(let text) = members[textMemberName] ?? .null {
            return text
        }
        if case .string(let blob) = members[blobMemberName] ?? .null {
            return folded(blob: blob, uri: uriMember(of: members))
        }
        return
            "The embedded resource `\(uriMember(of: members))` carries no text and no blob, so nothing is included."
    }

    /// Folds one blob payload as its decoded UTF-8 text, or a reasoned
    /// note that names the resource.
    ///
    /// - Parameters:
    ///   - blob: The base64 payload.
    ///   - uri: The resource's URI, for the note.
    /// - Returns: The decoded text, or the note.
    private static func folded(blob: String, uri: String) -> String {
        guard let data = Data(base64Encoded: blob),
            let text = String(data: data, encoding: .utf8)
        else {
            return "The embedded resource `\(uri)` is not UTF-8 text, so its blob is not included."
        }
        return text
    }

    /// The `uri` member of an embedded payload, or a fixed label when
    /// the member is absent.
    ///
    /// - Parameter members: The payload's members.
    /// - Returns: The URI, or the label.
    private static func uriMember(of members: [String: FoundationModelsACP.JSONValue]) -> String {
        if case .string(let uri) = members[uriMemberName] ?? .null {
            return uri
        }
        return "unnamed resource"
    }

    // MARK: - The MCP passthrough map (plan.md §12)

    /// Maps one MCP tool result's content to `tool_call_update` content
    /// items, in order. ACP's `ContentBlock` IS MCP's, so the map keeps
    /// the shape and loses nothing.
    ///
    /// - Parameter content: The MCP tool result's content.
    /// - Returns: The content items.
    static func toolCallContent(from content: [MCP.Tool.Content]) -> [ToolCallContent] {
        content.map { .content(Content(content: contentBlock(from: $0))) }
    }

    /// Maps one MCP content block to the ACP block of the same type.
    /// Every case has a same-shaped peer; no arm degrades to text.
    ///
    /// - Parameter content: The MCP content block.
    /// - Returns: The ACP block.
    static func contentBlock(from content: MCP.Tool.Content) -> ContentBlock {
        switch content {
        case .text(let text, let sourceAnnotations, _):
            .text(
                TextContent(
                    text: text, annotations: annotations(from: sourceAnnotations)))
        case .image(let data, let mimeType, let sourceAnnotations, _):
            .image(
                ImageContent(
                    data: data, mimeType: MediaType(rawValue: mimeType),
                    annotations: annotations(from: sourceAnnotations)))
        case .audio(let data, let mimeType, let sourceAnnotations, _):
            .audio(
                AudioContent(
                    data: data, mimeType: MediaType(rawValue: mimeType),
                    annotations: annotations(from: sourceAnnotations)))
        case .resource(let resource, let sourceAnnotations, _):
            .resource(
                EmbeddedResource(
                    resource: resourceValue(from: resource),
                    annotations: annotations(from: sourceAnnotations)))
        case .resourceLink(
            let uri, let name, let title, let description, let mimeType, let sourceAnnotations):
            .resourceLink(
                ResourceLink(
                    name: name,
                    uri: uri,
                    annotations: annotations(from: sourceAnnotations),
                    description: description,
                    mimeType: mimeType.map(MediaType.init(rawValue:)),
                    title: title))
        }
    }

    /// The wire payload of one MCP embedded resource: the URI always,
    /// then the MIME type, the text, and the blob where present.
    ///
    /// - Parameter resource: The MCP resource content.
    /// - Returns: The payload as wire JSON.
    private static func resourceValue(
        from resource: MCP.Resource.Content
    ) -> FoundationModelsACP.JSONValue {
        var members: [String: FoundationModelsACP.JSONValue] = [
            uriMemberName: .string(resource.uri)
        ]
        if let mimeType = resource.mimeType {
            members[mimeTypeMemberName] = .string(mimeType)
        }
        if let text = resource.text {
            members[textMemberName] = .string(text)
        }
        if let blob = resource.blob {
            members[blobMemberName] = .string(blob)
        }
        return .object(members)
    }

    /// Maps MCP annotations to the ACP annotations of the same shape:
    /// the audience roles, the priority, and the last-modified stamp.
    ///
    /// - Parameter source: The MCP annotations, or `nil`.
    /// - Returns: The ACP annotations, or `nil`.
    private static func annotations(
        from source: MCP.Resource.Annotations?
    ) -> FoundationModelsACP.Annotations? {
        guard let source else { return nil }
        return FoundationModelsACP.Annotations(
            audience: source.audience.map { $0.map(role(from:)) },
            lastModified: source.lastModified,
            priority: source.priority)
    }

    /// Maps one MCP audience member to the ACP role of the same name.
    ///
    /// - Parameter audience: The MCP audience member.
    /// - Returns: The ACP role.
    private static func role(from audience: MCP.Resource.Annotations.Audience) -> Role {
        switch audience {
        case .user: .user
        case .assistant: .assistant
        }
    }
}

/// Resolves a prompt `resource_link` through the mounted files verb
/// (plan.md §12).
///
/// `resource_link` is not capability-gated and can always arrive. A
/// `file://` URI resolves through `tools.files.read`, the same bounded
/// door the model reads through: a path outside the session's root set
/// comes back refused **in band** through the output's `correction`
/// field — the files verbs return corrections and do not throw — and
/// that correction becomes the reasoned refusal. Every other scheme is
/// refused here with a reason: a silent fetch of an `http://` URI from
/// a prompt is a request the user did not make.
struct ResourceLinkResolver: Sendable {
    /// The one URI scheme this resolver reads.
    static let fileScheme = "file"

    /// The read format the resolver asks for, so the folded text
    /// carries no hashline anchor.
    private static let plainFormatName = "plain"

    /// The mounted `tools.files.read` verb, or `nil` when the files
    /// section is off for the session.
    let readVerb: (any FoundationModels.Tool)?

    /// The slice of the read verb's wire result the resolver reads. The
    /// verb's own output struct is internal upstream; the wire JSON is
    /// the public shape (plan.md §11.4).
    private struct ReadOutcome: Decodable {
        /// Why the read answered no content, or `nil` when the content
        /// stands.
        let correction: String?

        /// The file's lines, in the plain format.
        let lines: [String]
    }

    /// The failure of an output the resolver cannot decode. The files
    /// verbs answer generable outputs, so this does not occur in
    /// practice; the arm keeps the decode total.
    private struct UnreadableOutputError: Error, CustomStringConvertible {
        /// The reason the refusal reports.
        let description = "the files verb answered an output the resolver cannot decode"
    }

    /// Resolves `uri` to the linked file's text, or to the reasoned
    /// refusal. Never throws: a refusal is prompt content, not a turn
    /// failure.
    ///
    /// - Parameter uri: The `resource_link` URI.
    /// - Returns: The file's text, or the refusal.
    func resolve(uri: String) async -> String {
        guard let url = URL(string: uri), let scheme = url.scheme else {
            return Self.refusal(uri: uri, reason: "the URI does not parse")
        }
        guard scheme.lowercased() == Self.fileScheme else {
            return Self.refusal(
                uri: uri,
                reason:
                    "this agent reads only file:// resources, and it does not fetch remote content")
        }
        guard let readVerb else {
            return Self.refusal(
                uri: uri, reason: "the files capability is not mounted for this session")
        }
        do {
            let outcome = try await Self.read(
                path: url.path(percentEncoded: false), with: readVerb)
            if let correction = outcome.correction {
                return Self.refusal(uri: uri, reason: correction)
            }
            return outcome.lines.joined(separator: "\n")
        } catch {
            return Self.refusal(uri: uri, reason: String(describing: error))
        }
    }

    /// Reads `path` through the verb and decodes the wire result.
    ///
    /// - Parameters:
    ///   - path: The absolute path of the file.
    ///   - verb: The mounted read verb.
    /// - Returns: The decoded outcome.
    /// - Throws: What the invocation throws, or
    ///   ``UnreadableOutputError`` for an output that does not decode.
    private static func read(
        path: String, with verb: any FoundationModels.Tool
    ) async throws -> ReadOutcome {
        let argumentsJSON = String(
            decoding: try JSONEncoder().encode(["path": path, "format": plainFormatName]),
            as: UTF8.self)
        let output = try await ToolInvoker.invoke(
            verb, content: try GeneratedContent(json: argumentsJSON))
        guard let convertible = output as? any ConvertibleToGeneratedContent else {
            throw UnreadableOutputError()
        }
        return try JSONDecoder().decode(
            ReadOutcome.self, from: Data(convertible.generatedContent.jsonString.utf8))
    }

    /// The reasoned refusal a prompt carries in place of the linked
    /// file's text.
    ///
    /// - Parameters:
    ///   - uri: The refused URI.
    ///   - reason: Why the resource was not read.
    /// - Returns: The refusal text.
    private static func refusal(uri: String, reason: String) -> String {
        "The resource link `\(uri)` was not read: \(reason)."
    }
}
