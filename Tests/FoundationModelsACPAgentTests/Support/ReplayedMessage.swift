import FoundationModelsACP

// MARK: - The replay readers (plan.md §7.4, §8.3)
//
// A `session/resume` with `replayFrom` sends each kept message as one
// whole-message upsert. `SessionResumeTests`, `PromptExecutionTests` and
// `SessionHistoryTests` compare those upserts with the live messages, so
// the readers live here, one time.

/// One replayed message, as both the live stream and the replay show it.
struct ReplayedMessage: Equatable {
    /// Which whole-message form carried it.
    let kind: Kind

    /// The message id on the wire.
    let id: String

    /// The joined text content.
    let text: String

    /// The three whole-message forms replay sends.
    enum Kind: Equatable {
        /// A `user_message` upsert.
        case user

        /// An `agent_message` upsert.
        case agent

        /// An `agent_thought` upsert.
        case thought
    }

    /// The whole-message upserts in a raw update sequence.
    ///
    /// - Parameter updates: The recorded raw updates.
    /// - Returns: The messages, in arrival order.
    static func replayed(in updates: [SessionUpdate]) -> [ReplayedMessage] {
        updates.compactMap { update in
            switch update {
            case .userMessage(let message):
                return ReplayedMessage(
                    kind: .user, id: message.messageId.rawValue, text: text(of: message.content))
            case .agentMessage(let message):
                return ReplayedMessage(
                    kind: .agent, id: message.messageId.rawValue, text: text(of: message.content))
            case .agentThought(let message):
                return ReplayedMessage(
                    kind: .thought, id: message.messageId.rawValue, text: text(of: message.content))
            default:
                return nil
            }
        }
    }

    /// The messages that a live update sequence carries: one row for each
    /// message, in the order of first appearance. The chunks of one message
    /// join into one text, and a whole-message update replaces the text.
    /// A replay that keeps the live ids sends these messages.
    ///
    /// - Parameter updates: The live raw updates.
    /// - Returns: The messages, in the order of first appearance.
    static func live(in updates: [SessionUpdate]) -> [ReplayedMessage] {
        updates.compactMap(livePiece(of:)).reduce(into: []) { messages, piece in
            let message = piece.message
            guard let index = messages.firstIndex(where: { $0.kind == message.kind && $0.id == message.id })
            else {
                messages.append(message)
                return
            }
            let text = piece.replaces ? message.text : messages[index].text + message.text
            messages[index] = ReplayedMessage(kind: message.kind, id: message.id, text: text)
        }
    }

    /// The part of one message that one live update carries, or `nil` for
    /// an update that carries no message.
    ///
    /// - Parameter update: The live update.
    /// - Returns: The message part, and whether it replaces the text that
    ///   came before (a whole-message update) or adds to it (a chunk).
    private static func livePiece(of update: SessionUpdate) -> (message: ReplayedMessage, replaces: Bool)? {
        switch update {
        case .userMessageChunk(let chunk):
            return (ReplayedMessage(kind: .user, id: chunk.messageId.rawValue, text: text(of: chunk.content)), false)
        case .agentMessageChunk(let chunk):
            return (ReplayedMessage(kind: .agent, id: chunk.messageId.rawValue, text: text(of: chunk.content)), false)
        case .agentThoughtChunk(let chunk):
            return (
                ReplayedMessage(kind: .thought, id: chunk.messageId.rawValue, text: text(of: chunk.content)), false
            )
        default:
            return replayed(in: [update]).first.map { ($0, true) }
        }
    }

    /// The joined text of a whole-message content patch.
    ///
    /// - Parameter content: The message's content patch.
    /// - Returns: The joined text of its text blocks; empty otherwise.
    private static func text(of content: PatchField<[ContentBlock]>?) -> String {
        guard case .value(let blocks)? = content else {
            return ""
        }
        return blocks.map(text(of:)).joined()
    }

    /// The text of one content block.
    ///
    /// - Parameter block: The content block.
    /// - Returns: The text of a text block; empty for every other block.
    private static func text(of block: ContentBlock) -> String {
        guard case .text(let text) = block else {
            return ""
        }
        return text.text
    }
}
