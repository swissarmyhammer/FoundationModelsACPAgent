import FoundationModelsACP

/// The display items that each tool call keeps to its end (task ^f9wmtse).
///
/// A diff display event of a tool goes to the client as a
/// `tool_call_content_chunk`, and the client appends it to the content of
/// the call. The settlement of a shell run puts the `Terminal` item of the
/// run in the content of the call. Each later update of the call that is
/// not a display event sends its content as a full replace: the progress,
/// the attachment report, the settlement and the SDK `toolStatus` that
/// completes the call. Without this record, such a replace removes the diff
/// and the terminal from the client, and the client never shows the change.
///
/// Thus each such replace sends the kept items of the call first, in the
/// order that they came, and its own items after them
/// (``content(for:adding:)``). A replace that adds no item sends no
/// `content` field, because an absent field keeps the content on the
/// client. A text or a JSON display part is not kept: it is output of the
/// tool that a later replace replaces, as before.
///
/// The record keys on the wire id of the call. It keeps the items of the
/// newest ``callLimit`` calls, so a long session holds a bounded record.
struct KeptDisplayItems: Sendable {
  /// The most tool calls whose items the record keeps. A call that is
  /// older than the newest calls of the limit is long finished, so its
  /// content gets no later replace.
  static let callLimit = 256

  /// The kept items, by the wire id of the call.
  private var items = BoundedTable<[ToolCallContent]>(limit: callLimit)

  /// Keeps `added` after the kept items of the call. No item adds nothing,
  /// so the record then stays as it is.
  ///
  /// - Parameters:
  ///   - added: The display items that the client put in the call.
  ///   - toolCallId: The wire id of the call.
  mutating func append(contentsOf added: [ToolCallContent], to toolCallId: ToolCallId) {
    guard !added.isEmpty else { return }
    items.store((items[toolCallId.rawValue] ?? []) + added, for: toolCallId.rawValue)
  }

  /// Replaces the kept items of the call. A content replace of the tool
  /// replaces the whole content on the client, so the record then keeps the
  /// items of that replace alone.
  ///
  /// - Parameters:
  ///   - kept: The items of the replace that the record keeps.
  ///   - toolCallId: The wire id of the call.
  mutating func replace(with kept: [ToolCallContent], for toolCallId: ToolCallId) {
    items.store(kept, for: toolCallId.rawValue)
  }

  /// The content patch of a replace that is not a display event: the kept
  /// items of the call, then the items of `result`.
  ///
  /// A call with no kept item gets `result` as it is. With kept items, a
  /// `result` that adds no item gives no change, so the client keeps the
  /// kept items. A `result` that is not a value stays as it is.
  ///
  /// - Parameters:
  ///   - toolCallId: The wire id of the call.
  ///   - result: The content patch that the update gives on its own.
  /// - Returns: The content patch to send.
  func content(
    for toolCallId: ToolCallId, adding result: PatchField<[ToolCallContent]>
  ) -> PatchField<[ToolCallContent]> {
    guard let kept = items[toolCallId.rawValue], !kept.isEmpty else {
      return result
    }
    switch result {
    case .value(let added) where added.isEmpty:
      return .unchanged
    case .value(let added):
      return .value(kept + added)
    case .unchanged, .cleared:
      return result
    }
  }
}
