import FoundationModelsACP

/// Runs `call` and returns the typed error that it throws.
///
/// - Parameter call: The request of the client.
/// - Returns: The typed error, or `nil` when the call did not throw one. A call that throws
///   another error (for example a failed transport) gives `nil`, so a refusal check fails then.
public func requestErrorThrown(by call: () async throws -> Void) async -> RequestError? {
  do {
    try await call()
    return nil
  } catch let error as RequestError {
    return error
  } catch {
    return nil
  }
}

/// Whether `error` is the refusal of a method that the capabilities of the session do not permit:
/// invalid params, with the session id, the method and the reason in `data`.
///
/// - Parameters:
///   - error: The error of the request.
///   - method: The method that the refusal must name.
///   - sessionId: The session that the refusal must name.
/// - Returns: `true` for the typed refusal of that method and session.
public func isMethodRefusal(
  _ error: RequestError?, of method: String, on sessionId: SessionId
) -> Bool {
  guard let error else {
    return false
  }
  return error.code == .invalidParams
    && error.message == RequestError.invalidParams.message
    && errorDataField("sessionId", of: error) == sessionId.rawValue
    && errorDataField("method", of: error) == method
    && errorDataField("reason", of: error)
      == "the session \(sessionId.rawValue) does not permit \(method)"
}
