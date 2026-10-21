import Foundation
import FoundationModelsACP
import FoundationModelsExtras
import GraphQL

/// The JSON conversions of the GraphQL tunnel (ACPA-13): the wire carries
/// the variables and the results as JSON (D79), and a `GraphQLEndpoint`
/// takes GraphQL `Map` values and gives its response as JSON text.
enum GraphQLTunnelJSON {
    /// Gives the variables of a call as the `Map` values that an endpoint
    /// takes.
    ///
    /// - Parameter variables: The `variables` of the call, or `nil`.
    /// - Returns: The variables; no variables, or JSON `null`, give none.
    /// - Throws: `INVALID_VARIABLES` of the toolkit when the variables are
    ///   not a JSON object; an error of the JSON coders.
    static func variables(from variables: JSONValue?) throws -> [String: Map] {
        guard let variables, variables != .null else {
            return [:]
        }
        guard case .object = variables else {
            throw GraphQLToolkitError.invalidVariables(received: kindName(of: variables))
        }
        return try JSONDecoder().decode([String: Map].self, from: JSONEncoder().encode(variables))
    }

    /// Reads the JSON text of the response of an endpoint as a result of the
    /// tunnel.
    ///
    /// - Parameter text: The `{data, errors, extensions}` JSON text.
    /// - Returns: The result.
    /// - Throws: A `DecodingError` when the text is not a GraphQL response.
    static func result(fromResponse text: String) throws -> SAH.GraphQL.ExecutionResult {
        try JSONDecoder().decode(SAH.GraphQL.ExecutionResult.self, from: Data(text.utf8))
    }

    /// The result of a call that fails as a whole: the error in `errors`,
    /// with its code, and no data. An error that is not a ``CodedError``
    /// gives `INTERNAL` with only its type name, because its description can
    /// hold content.
    ///
    /// - Parameter error: The error of the call.
    /// - Returns: The result.
    static func result(failingWith error: any Error) -> SAH.GraphQL.ExecutionResult {
        let coded =
            error as? any CodedError
            ?? GraphQLToolkitError.internalFailure(detail: ACPAgentTelemetry.errorTypeName(of: error))
        do {
            return try result(fromResponse: coded.responseJSON())
        } catch {
            assertionFailure("the response of a coded error did not encode: \(error)")
            ACPAgentTelemetry.logger(.graphQLTunnel).error(
                "The response of a coded error did not encode. The result has the error message alone.",
                metadata: ACPAgentTelemetry.errorMetadata(error))
            return SAH.GraphQL.ExecutionResult(errors: [.object([messageKey: .string(coded.message)])])
        }
    }

    /// The key of the message of a GraphQL error.
    private static let messageKey = "message"

    /// What a JSON value is, for the message of `INVALID_VARIABLES`.
    ///
    /// - Parameter value: The value.
    /// - Returns: For example `a number`.
    private static func kindName(of value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "a list"
        case .object: "an object"
        }
    }
}
