import FoundationModelsACP
import FoundationModelsRouter

// MARK: - The replay readers (plan.md §7.4, §8.3)
//
// A `session/resume` with `replayFrom` sends each recorded message as one
// whole-message upsert. `SessionResumeTests` and `PromptExecutionTests`
// compare those upserts with the recorded events, so the two readers live
// here, one time.

/// One replayed message, as both the recording and the wire show it.
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

    /// The messages replay is expected to send for `events`: one row per
    /// recorded `.prompt`, `.reasoning`, and `.response` event, keyed by
    /// the recorded first segment id.
    ///
    /// - Parameter events: The session's recorded events, in order.
    /// - Returns: The expected messages, in order.
    static func expected(from events: [TranscriptEvent]) -> [ReplayedMessage] {
        events.compactMap { event in
            let kind: Kind
            switch event.kind {
            case .prompt:
                kind = .user
            case .reasoning:
                kind = .thought
            case .response:
                kind = .agent
            default:
                return nil
            }
            guard let segments = event.entry?.segments,
                case .text(let id, let content) = segments.first
            else {
                return nil
            }
            return ReplayedMessage(kind: kind, id: id, text: content)
        }
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

    /// The joined text of a whole-message content patch.
    ///
    /// - Parameter content: The message's content patch.
    /// - Returns: The joined text of its text blocks; empty otherwise.
    private static func text(of content: PatchField<[ContentBlock]>?) -> String {
        guard case .value(let blocks)? = content else {
            return ""
        }
        return blocks.compactMap { block in
            if case .text(let text) = block {
                return text.text
            }
            return nil
        }.joined()
    }
}
