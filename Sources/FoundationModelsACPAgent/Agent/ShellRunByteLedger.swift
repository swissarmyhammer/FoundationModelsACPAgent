import FoundationModelsMultitool

/// The byte offsets of one shell run, as the terminal projection saw them,
/// for each of its two streams (task ^pxncjnk).
///
/// A replacement from `snapshot(for:)` holds each byte that the store took
/// for the run at the time of the call. The upstream queue can still hold
/// output chunks of the run whose bytes the store took before that call.
/// Thus a chunk that comes after a replacement can repeat bytes that the
/// replacement already put on the wire. The ledger finds those bytes by
/// counting, not by a comparison of bytes:
///
/// - Inside one stream of one run, the events come in the order the child
///   wrote, each output event carries its bytes whole, and each gap event
///   counts each byte that went away. Thus the sum of the output bytes and
///   the gap counts of one stream is the end offset of the last event of
///   that stream.
/// - The store behind the snapshot takes each chunk before the upstream
///   budget test. Thus, when the snapshot is not truncated, the byte count
///   of one stream of the snapshot is the end offset of that stream at the
///   time of the call.
///
/// A truncated snapshot is not necessarily a prefix of the output, so it
/// gives no offset. After such a replacement the ledger lets no byte of the
/// run through. The completion replacement, which is the store in all
/// cases, then gives the final view.
struct ShellRunByteLedger {
    /// Where the client view of one stream ends after the last replacement.
    enum ReplacementEnd {
        /// The view holds each byte of the stream before this offset.
        case offset(Int)

        /// A truncated snapshot replaced the view, so no offset is known.
        /// No later byte of the stream goes on the wire.
        case unknown
    }

    /// The offsets of one stream of the run.
    struct StreamOffsets {
        /// The end offset of the last event of the stream that the
        /// projection read: the output bytes and the gap counts together.
        var deliveredEnd = 0

        /// Where the client view of the stream ends after the last
        /// replacement. Before any replacement it is offset zero, so each
        /// byte goes on the wire.
        var replacementEnd = ReplacementEnd.offset(0)
    }

    /// The offsets of each stream of the run that sent an event.
    private var streams: [ShellOutputStream: StreamOffsets] = [:]

    /// Moves the delivered end of a stream past one event, and gives the
    /// bytes of an output event that the client view does not hold yet.
    ///
    /// - Parameter kind: The kind of the event that the projection read.
    /// - Returns: The bytes of an output event past the end of the last
    ///   replacement. It is empty for a gap, for a completion marker, and
    ///   for an output event whose bytes the replacement holds.
    mutating func advance(past kind: ShellOutputEvent.Kind) -> ArraySlice<UInt8> {
        switch kind {
        case .output(let stream, let bytes):
            return newBytes(of: bytes, from: stream)
        case .gap(let stream, let droppedByteCount):
            streams[stream, default: StreamOffsets()].deliveredEnd += droppedByteCount
            return []
        case .completed:
            return []
        @unknown default:
            // The upstream kind is not frozen: a new case carries no bytes
            // that the ledger can place.
            return []
        }
    }

    /// Records the end of the client view of each stream after a
    /// replacement built from `snapshot`.
    ///
    /// - Parameter snapshot: The stored output that replaced the view.
    mutating func recordReplacement(by snapshot: ShellOutputSnapshot) {
        streams[.stdout, default: StreamOffsets()].replacementEnd = Self.end(of: snapshot.stdout)
        streams[.stderr, default: StreamOffsets()].replacementEnd = Self.end(of: snapshot.stderr)
    }

    /// Moves the delivered end of `stream` past `bytes`, and gives the part
    /// of `bytes` past the end of the last replacement.
    ///
    /// - Parameters:
    ///   - bytes: The bytes of one output event.
    ///   - stream: The stream that the bytes came from.
    /// - Returns: The bytes that the client view does not hold yet.
    private mutating func newBytes(of bytes: [UInt8], from stream: ShellOutputStream) -> ArraySlice<UInt8> {
        var offsets = streams[stream, default: StreamOffsets()]
        let start = offsets.deliveredEnd
        offsets.deliveredEnd += bytes.count
        streams[stream] = offsets
        guard case .offset(let viewEnd) = offsets.replacementEnd else {
            return []
        }
        return bytes.dropFirst(max(viewEnd - start, 0))
    }

    /// The end of the client view of one stream after a replacement that
    /// holds `raw`.
    ///
    /// - Parameter raw: The stored bytes of one stream.
    /// - Returns: The byte count as the offset, or ``ReplacementEnd/unknown``
    ///   for a truncated capture.
    private static func end(of raw: ShellRawOutput) -> ReplacementEnd {
        raw.truncated ? .unknown : .offset(raw.bytes.count)
    }
}
