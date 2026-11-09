import FoundationModels
import FoundationModelsExtras
import FoundationModelsKanban

/// The `kanban` tool in the shape that the Multitool registry mounts under a
/// noun: ``KanbanTool`` plus ``OperationDescribing``.
///
/// The registry shows one verb, `tools.kanban.runKanban`, whose parameters are the
/// parts of a GraphQL call. The tool gives the same answer as ``KanbanTool``,
/// and the same endpoint to the GraphQL tunnel.
struct KanbanOperationTool: GraphQLEndpointTool, OperationDescribing {
  /// The op string of the one operation of the tool.
  static let runOperation = "run kanban"

  /// The verb of ``runOperation``.
  private static let runVerb = "run"

  /// The noun of ``runOperation``, and the noun of the registry mount.
  static let noun = "kanban"

  /// The key of the op string in a payload of ``perform(_:)``.
  private static let operationKey = "op"

  /// The failures of ``perform(_:)``.
  enum PayloadError: Error, Equatable {
    /// The payload has no `op` string.
    case missingOperation

    /// The payload names an operation that the tool does not have.
    case unknownOperation(String)
  }

  /// The name of the tool.
  var name: String { inner.name }

  /// The description of the tool for the model.
  var description: String { inner.description }

  /// The schema of the arguments.
  var parameters: GenerationSchema { inner.parameters }

  /// The tool that runs each document.
  private let inner: KanbanTool

  /// Makes the tool over a Kanban tool.
  ///
  /// - Parameter inner: The tool of the session.
  init(_ inner: KanbanTool) {
    self.inner = inner
  }

  /// The endpoints of the inner tool.
  var graphQLEndpoints: [any GraphQLEndpoint] {
    inner.graphQLEndpoints
  }

  /// Runs the document of the arguments.
  ///
  /// - Parameter arguments: The decoded arguments of the call.
  /// - Returns: The GraphQL response as JSON text.
  /// - Throws: A fault of the engine.
  func call(arguments: KanbanArguments) async throws -> String {
    try await inner.call(arguments: arguments)
  }

  /// The one operation of the tool, whose parameters are the parts of a
  /// GraphQL call.
  var operationDescriptors: [OperationDescriptor] {
    [
      OperationDescriptor(
        verb: Self.runVerb, noun: Self.noun, opString: Self.runOperation,
        description: inner.description,
        parameters: GraphQLArguments.parameterDescriptors)
    ]
  }

  /// Runs the document of one `op` payload.
  ///
  /// - Parameter arguments: The payload: `op` is ``runOperation``, and the
  ///   other keys are the arguments of ``call(arguments:)``.
  /// - Returns: The GraphQL response as JSON text.
  /// - Throws: ``PayloadError`` when the payload has no `op` or another
  ///   `op`; the error of the arguments when the payload has no `query`; a
  ///   fault of the engine.
  func perform(_ arguments: GeneratedContent) async throws -> String {
    guard case .structure(let properties, _) = arguments.kind,
      case .string(let operation)? = properties[Self.operationKey]?.kind
    else {
      throw PayloadError.missingOperation
    }
    guard operation == Self.runOperation else {
      throw PayloadError.unknownOperation(operation)
    }
    return try await call(arguments: KanbanArguments(arguments))
  }
}
