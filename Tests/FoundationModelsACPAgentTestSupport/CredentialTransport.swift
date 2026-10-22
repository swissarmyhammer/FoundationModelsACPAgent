import Foundation
import FoundationModelsACP

/// One end of a wire that reports the id and the credential of an HTTP
/// connection (ACP-1), over any other end.
///
/// `HTTPConnectionTransport` gives the agent an `ACPConnectionInfo` with the
/// `Acp-Connection-Id` and the bearer token of the connection. This wrapper
/// gives the same value over the in-process wire, so a suite can bind a
/// connection with a credential and no socket (ACPA-5b). The bytes and the
/// writes are those of the wrapped end, unchanged.
public struct CredentialTransport: ACPTransport {
    /// The incoming chunks of the wrapped end.
    public var bytes: AsyncThrowingStream<Data, any Error> { base.bytes }

    /// The id and the credential that this end reports.
    public let connectionInfo: ACPConnectionInfo?

    /// The wrapped end, which carries the bytes in both directions.
    private let base: any ACPTransport

    /// Wraps `base` and reports `connectionInfo` for it.
    ///
    /// - Parameters:
    ///   - base: The end that carries the bytes.
    ///   - connectionInfo: The id and the credential to report.
    public init(wrapping base: any ACPTransport, reporting connectionInfo: ACPConnectionInfo) {
        self.base = base
        self.connectionInfo = connectionInfo
    }

    /// Writes one chunk through the wrapped end.
    ///
    /// - Parameter data: The framed bytes to send.
    /// - Throws: The write error of the wrapped end.
    public func write(_ data: Data) async throws {
        try await base.write(data)
    }
}

/// The bearer tokens that the suites give their connections (ACPA-5b).
public enum TestBearerToken {
    /// A token of a device of the user: a suite lists it in the
    /// `userDeviceTokens` of its agent.
    public static let userDevice = "token-of-a-device-of-the-user"

    /// A token that no agent of the suites lists, so it names no device of
    /// the user.
    public static let other = "token-of-another-client"
}

extension ACPConnectionInfo {
    /// The information of a new HTTP connection: a fresh
    /// `Acp-Connection-Id`, as the server issues one at `initialize`, and
    /// the bearer token of its `Authorization` header.
    ///
    /// - Parameter bearerToken: The bearer token of the connection.
    /// - Returns: The information.
    public static func makeHTTP(bearerToken: String) -> ACPConnectionInfo {
        ACPConnectionInfo(id: ACPConnectionId(rawValue: UUID().uuidString), bearerToken: bearerToken)
    }
}
