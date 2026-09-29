// `OTLPTestReceiver` — a small OTLP/HTTP collector for the telemetry suites.
//
// A spawned `acp-agent` exports its spans, log records and metrics over
// OTLP/HTTP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. This receiver listens
// on the loopback address, records the path and the body of each request,
// and answers each request with the success answer that swift-otel accepts:
// `200 OK`, `Content-Type: application/json` and the body `{}`. A suite sets
// `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`, so the recorded bodies are JSON
// and the suite can read the span names.

import Foundation
import Network
import Synchronization

/// One HTTP request the receiver recorded.
struct OTLPRecordedRequest: Sendable {
    /// The request path, for example `/v1/traces`.
    let path: String

    /// The request body.
    let body: Data
}

/// What went wrong with the receiver.
enum OTLPTestReceiverError: Error, CustomStringConvertible {
    /// The listener did not become ready.
    case listenerFailed(String)

    var description: String {
        switch self {
        case .listenerFailed(let reason):
            "the OTLP test receiver did not start: \(reason)"
        }
    }
}

/// A local OTLP/HTTP receiver that records each request body.
///
/// It reads HTTP/1.1 requests with a `Content-Length` body or a chunked body,
/// on a connection that the exporter keeps open for more than one request.
final class OTLPTestReceiver: Sendable {
    /// The path of the OTLP/HTTP trace export.
    static let tracesPath = "/v1/traces"

    /// The loopback address the receiver listens on.
    private static let loopbackHost = "127.0.0.1"

    /// The most bytes one read of a connection takes.
    private static let maximumReadLength = 65_536

    /// The answer to each request: a success with an empty JSON object, as
    /// the OTLP/HTTP JSON encoding expects.
    private static let successResponse = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)

    /// The listener on the loopback address.
    private let listener: NWListener

    /// The queue of the listener and of each connection.
    private let queue: DispatchQueue

    /// The requests recorded so far.
    private let recorded = Mutex<[OTLPRecordedRequest]>([])

    /// The port the listener got from the system.
    let port: UInt16

    /// The value for `OTEL_EXPORTER_OTLP_ENDPOINT`.
    var endpoint: String {
        "http://\(Self.loopbackHost):\(port)"
    }

    /// The requests recorded so far.
    var requests: [OTLPRecordedRequest] {
        recorded.withLock { $0 }
    }

    /// The name of each span in each trace export recorded so far.
    var spanNames: [String] {
        requests
            .filter { $0.path == Self.tracesPath }
            .flatMap { OTLPJSONSpans.names(in: $0.body) }
    }

    /// Wraps a ready listener.
    ///
    /// - Parameters:
    ///   - listener: The listener, ready on `port`.
    ///   - queue: The queue of the listener.
    ///   - port: The port of the listener.
    private init(listener: NWListener, queue: DispatchQueue, port: UInt16) {
        self.listener = listener
        self.queue = queue
        self.port = port
    }

    /// Starts a receiver on a free port of the loopback address, and waits
    /// until it listens.
    ///
    /// - Returns: The running receiver.
    /// - Throws: ``OTLPTestReceiverError/listenerFailed(_:)`` when the
    ///   listener does not become ready, or the listener creation error.
    static func start() async throws -> OTLPTestReceiver {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(loopbackHost), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "OTLPTestReceiver")
        let port = try await waitUntilReady(listener, on: queue)
        let receiver = OTLPTestReceiver(listener: listener, queue: queue, port: port)
        listener.newConnectionHandler = { connection in
            receiver.serve(connection)
        }
        return receiver
    }

    /// Stops the listener. A connection that is open stays open until its
    /// peer closes it.
    func stop() {
        listener.cancel()
    }

    /// Starts `listener` and waits for its first state that decides: ready,
    /// or failed.
    ///
    /// - Parameters:
    ///   - listener: The listener to start.
    ///   - queue: The queue of the listener.
    /// - Returns: The port the listener got.
    /// - Throws: ``OTLPTestReceiverError/listenerFailed(_:)``.
    private static func waitUntilReady(_ listener: NWListener, on queue: DispatchQueue) async throws
        -> UInt16
    {
        let (states, report) = AsyncStream<NWListener.State>.makeStream()
        listener.stateUpdateHandler = { state in
            report.yield(state)
        }
        listener.newConnectionHandler = { connection in
            connection.cancel()
        }
        listener.start(queue: queue)
        for await state in states {
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                report.finish()
                guard let port = listener.port?.rawValue else {
                    throw OTLPTestReceiverError.listenerFailed("the ready listener has no port")
                }
                return port
            case .failed(let error):
                report.finish()
                throw OTLPTestReceiverError.listenerFailed("\(error)")
            case .cancelled:
                report.finish()
                throw OTLPTestReceiverError.listenerFailed("the listener was cancelled")
            case .setup, .waiting:
                continue
            @unknown default:
                continue
            }
        }
        throw OTLPTestReceiverError.listenerFailed("the listener reported no state")
    }

    /// Starts one connection and reads its requests.
    ///
    /// - Parameter connection: The new connection.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNext(on: connection, pending: [])
    }

    /// Reads the next bytes of `connection`, records and answers each whole
    /// request, and reads again until the peer closes the connection.
    ///
    /// - Parameters:
    ///   - connection: The connection to read.
    ///   - pending: The bytes of a request that is not whole yet.
    private func receiveNext(on connection: NWConnection, pending: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReadLength) {
            data, _, isComplete, error in
            let remainder = self.answerWholeRequests(
                in: pending + (data.map { [UInt8]($0) } ?? []), on: connection)
            guard !isComplete, error == nil else {
                connection.cancel()
                return
            }
            self.receiveNext(on: connection, pending: remainder)
        }
    }

    /// Records and answers each whole request at the start of `bytes`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes read so far.
    ///   - connection: The connection that gets the answers.
    /// - Returns: The bytes after the last whole request.
    private func answerWholeRequests(in bytes: [UInt8], on connection: NWConnection) -> [UInt8] {
        var remainder = bytes
        while let (request, length) = HTTPRequestParser.parse(remainder) {
            recorded.withLock { $0.append(request) }
            connection.send(content: Self.successResponse, completion: .idempotent)
            remainder.removeFirst(length)
        }
        return remainder
    }
}

/// The parse of one HTTP/1.1 request from the start of a byte buffer.
private enum HTTPRequestParser {
    /// The bytes that end the head of a request.
    private static let headTerminator = Array("\r\n\r\n".utf8)

    /// The bytes that end one line of a chunked body.
    private static let lineTerminator = Array("\r\n".utf8)

    /// The radix of a chunk size.
    private static let chunkSizeRadix = 16

    /// Parses the request at the start of `bytes`.
    ///
    /// - Parameter bytes: The bytes read so far.
    /// - Returns: The request and the number of bytes it takes, or `nil`
    ///   when the request is not whole yet.
    static func parse(_ bytes: [UInt8]) -> (OTLPRecordedRequest, Int)? {
        guard let headEnd = firstIndex(of: headTerminator, in: bytes, from: 0) else {
            return nil
        }
        let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""
        let headers = Dictionary(
            lines.dropFirst().compactMap(headerPair), uniquingKeysWith: { _, last in last })
        let bodyStart = headEnd + headTerminator.count
        guard let (body, end) = readBody(of: bytes, from: bodyStart, headers: headers) else {
            return nil
        }
        return (OTLPRecordedRequest(path: path, body: Data(body)), end)
    }

    /// Splits one header line into its lowercased name and its value.
    ///
    /// - Parameter line: The header line.
    /// - Returns: The pair, or `nil` for a line with no colon.
    private static func headerPair(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else {
            return nil
        }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    /// Reads the body that starts at `start`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes read so far.
    ///   - start: The index of the first body byte.
    ///   - headers: The request headers, with lowercased names.
    /// - Returns: The body and the index after it, or `nil` when the body is
    ///   not whole yet.
    private static func readBody(
        of bytes: [UInt8], from start: Int, headers: [String: String]
    ) -> ([UInt8], Int)? {
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            return readChunkedBody(of: bytes, from: start)
        }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard bytes.count >= start + length else {
            return nil
        }
        return (Array(bytes[start..<(start + length)]), start + length)
    }

    /// Reads a chunked body that starts at `start`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes read so far.
    ///   - start: The index of the first chunk-size line.
    /// - Returns: The joined chunks and the index after the last chunk, or
    ///   `nil` when the body is not whole yet.
    private static func readChunkedBody(of bytes: [UInt8], from start: Int) -> ([UInt8], Int)? {
        var body: [UInt8] = []
        var cursor = start
        while true {
            guard let lineEnd = firstIndex(of: lineTerminator, in: bytes, from: cursor) else {
                return nil
            }
            let sizeText = String(decoding: bytes[cursor..<lineEnd], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: chunkSizeRadix)
            else {
                return nil
            }
            let dataStart = lineEnd + lineTerminator.count
            let dataEnd = dataStart + size
            guard bytes.count >= dataEnd + lineTerminator.count else {
                return nil
            }
            guard size > 0 else {
                return (body, dataEnd + lineTerminator.count)
            }
            body.append(contentsOf: bytes[dataStart..<dataEnd])
            cursor = dataEnd + lineTerminator.count
        }
    }

    /// Finds the first place of `pattern` in `bytes`, at `start` or later.
    ///
    /// - Parameters:
    ///   - pattern: The bytes to find.
    ///   - bytes: The bytes to search.
    ///   - start: The first index to look at.
    /// - Returns: The index where `pattern` starts, or `nil`.
    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= start + pattern.count else {
            return nil
        }
        return (start...(bytes.count - pattern.count)).first { index in
            bytes[index..<(index + pattern.count)].elementsEqual(pattern)
        }
    }
}

/// The span names of an OTLP/HTTP JSON trace export.
enum OTLPJSONSpans {
    /// Reads the name of each span in `body`: each
    /// `resourceSpans[].scopeSpans[].spans[].name`.
    ///
    /// - Parameter body: The JSON body of one trace export.
    /// - Returns: The span names, in the order of the body. A body that is
    ///   not JSON gives no name.
    static func names(in body: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return []
        }
        let resourceSpans = root["resourceSpans"] as? [[String: Any]] ?? []
        let scopeSpans = resourceSpans.flatMap { $0["scopeSpans"] as? [[String: Any]] ?? [] }
        let spans = scopeSpans.flatMap { $0["spans"] as? [[String: Any]] ?? [] }
        return spans.compactMap { $0["name"] as? String }
    }
}
