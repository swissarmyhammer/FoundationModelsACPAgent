import FoundationModelsACP
import struct FoundationModelsRouter.MailDeliveryPause

/// The report of a pause of the mail delivery of one session: one
/// `_mail_delivery_paused` session update for each
/// `SessionEvent.mailDeliveryPaused` (task ^t03jd5h).
///
/// Router holds new run mail when `mailOnlyAnswerLimit` answers in a row had
/// no caller message. The held mail starts no answer, and Router counts it as
/// idle, so with no report the client sees only `idle`. The next caller
/// message (`session/prompt`) carries the held mail into its answer, so that
/// message lifts the pause. The agent sends no update for the lift.
///
/// ACP keeps the names that start with `_` free for custom use, so the report
/// is an extension update kind. A client decodes it as
/// `SessionUpdate.unknown("_mail_delivery_paused", payload)` with no change
/// to FoundationModelsACP. The members of the update:
///
/// - `limit`: the limit in force, the most answers in a row that run mail
///   alone starts.
/// - `heldCount`: how many run results the session holds.
/// - `heldMail`: one object for each held result, in queue order: `tool`,
///   `op` and `completionToken` of the run.
/// - `message`: one line for a person, the text of the Router report.
///
/// Unlike `_mcp_server_status`, the update is part of the conversation: the
/// held results belong to the session. Thus it goes through the history sink,
/// the retained history keeps it, and a replay sends it again.
enum MailDeliveryPauseReport {
    /// The `sessionUpdate` value of the update.
    static let updateKind = "_mail_delivery_paused"

    /// The names of the members of the update.
    enum MemberName {
        /// The limit in force.
        static let limit = "limit"

        /// How many run results the session holds.
        static let heldCount = "heldCount"

        /// The held results.
        static let heldMail = "heldMail"

        /// The text for a person.
        static let message = "message"

        /// The tool of one held result.
        static let tool = "tool"

        /// The operation of one held result.
        static let op = "op"

        /// The completion token of the run of one held result.
        static let completionToken = "completionToken"
    }

    /// The update that reports `pause`.
    ///
    /// - Parameter pause: The pause that Router sent.
    /// - Returns: The `_mail_delivery_paused` update.
    static func update(for pause: MailDeliveryPause) -> SessionUpdate {
        let heldMail: [JSONValue] = pause.heldMail.map { event in
            .object([
                MemberName.tool: .string(event.tool),
                MemberName.op: .string(event.op),
                MemberName.completionToken: .string(event.correlationID),
            ])
        }
        return .unknown(
            updateKind,
            .object([
                MemberName.limit: .number(Double(pause.limit)),
                MemberName.heldCount: .number(Double(pause.heldMail.count)),
                MemberName.heldMail: .array(heldMail),
                MemberName.message: .string(pause.description),
            ]))
    }
}
