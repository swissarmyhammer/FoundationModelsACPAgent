import FoundationModelsACP

/// The marker of a tool call whose run continues in the background: the `_meta` of its
/// `tool_call_update`.
///
/// A background tool can return its pending envelope in place of its result. The call then stays
/// `in_progress` until the run ends. The update at the return carries the completion token of the
/// run in `_meta.sah.backgroundRun.completionToken`, a string. A client reads the marker to show
/// that the call runs in the background. The retained history keeps the marker, so a resume finds
/// the run of each open call from its token.
///
/// ACP patches `_meta` by top-level key, so the update replaces the whole `_meta.sah` object of the
/// call. The translator puts no other `_meta.sah` member on such a call. An `agents` call carries
/// `_meta.sah.agentRun`, so it never gets this marker.
enum BackgroundRunMeta {
  /// The `_meta.sah` member that holds the marker.
  static let backgroundRunKey = "backgroundRun"

  /// The member of the marker that holds the completion token of the run.
  static let completionTokenKey = "completionToken"

  /// The `_meta` value that marks a call whose run continues in the background.
  ///
  /// - Parameter completionToken: The completion token of the run.
  /// - Returns: The `_meta` object.
  static func meta(completionToken: String) -> JSONValue {
    .object([
      SAH.metaKey: .object([
        backgroundRunKey: .object([completionTokenKey: .string(completionToken)])
      ])
    ])
  }

  /// The completion token in the marker of a `_meta` value.
  ///
  /// - Parameter meta: The `_meta` value of a tool call, or `nil`.
  /// - Returns: The token, or `nil` when the value holds no marker.
  static func completionToken(in meta: JSONValue?) -> String? {
    guard case .object(let members)? = meta,
      case .object(let sah)? = members[SAH.metaKey],
      case .object(let run)? = sah[backgroundRunKey],
      case .string(let token)? = run[completionTokenKey]
    else {
      return nil
    }
    return token
  }
}
