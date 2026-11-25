import FoundationModels
import FoundationModelsACPAgent
import FoundationModelsExtras
import FoundationModelsKanban

/// The `kanban` tool in the shape that the Multitool registry mounts under a
/// noun: ``KanbanTool`` plus ``OperationDescribing``.
///
/// The registry shows one verb, `tools.kanban.runKanban`, whose parameters are the
/// parts of a GraphQL call. The tool gives the same answer as ``KanbanTool``,
/// and the same endpoint to the GraphQL tunnel.
///
/// A host gives ``sessionToolFactory`` (or ``sessionToolFactory(host:)``) to
/// `ComposedAgent.compose(..., sessionToolFactories:)`, so each session has
/// the tool. The `acp-agent` CLI gives the same factory.
public struct KanbanOperationTool: GraphQLEndpointTool, OperationDescribing {
  /// The op string of the one operation of the tool.
  public static let runOperation = "run kanban"

  /// The verb of ``runOperation``.
  private static let runVerb = "run"

  /// The noun of ``runOperation``, and the noun of the registry mount.
  public static let noun = "kanban"

  /// The key of the op string in a payload of ``perform(_:)``.
  private static let operationKey = "op"

  /// The failures of ``perform(_:)``.
  public enum PayloadError: Error, Equatable {
    /// The payload has no `op` string.
    case missingOperation

    /// The payload names an operation that the tool does not have.
    case unknownOperation(String)
  }

  /// The name of the tool.
  public var name: String { inner.name }

  /// The description of the tool for the model.
  public var description: String { inner.description }

  /// The schema of the arguments.
  public var parameters: GenerationSchema { inner.parameters }

  /// The tool that runs each document.
  private let inner: KanbanTool

  /// Makes the tool over a Kanban tool.
  ///
  /// - Parameter inner: The tool of the session.
  public init(_ inner: KanbanTool) {
    self.inner = inner
  }

  /// The endpoints of the inner tool.
  public var graphQLEndpoints: [any GraphQLEndpoint] {
    inner.graphQLEndpoints
  }

  /// Runs the document of the arguments.
  ///
  /// - Parameter arguments: The decoded arguments of the call.
  /// - Returns: The GraphQL response as JSON text.
  /// - Throws: A fault of the engine.
  public func call(arguments: KanbanArguments) async throws -> String {
    try await inner.call(arguments: arguments)
  }

  /// The one operation of the tool, whose parameters are the parts of a
  /// GraphQL call.
  public var operationDescriptors: [OperationDescriptor] {
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
  public func perform(_ arguments: GeneratedContent) async throws -> String {
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

  // MARK: - The factory of each session

  /// The factory of the `kanban` tool of each session, over
  /// ``KanbanHost/shared``. See ``sessionToolFactory(host:)``.
  public static let sessionToolFactory: SessionToolFactory = sessionToolFactory(host: .shared)

  /// The factory of the `kanban` tool of each session. It asks `host` for a
  /// view of the board of the folder of the session. The host keeps one
  /// engine for each folder, and the view lives as long as the tool holds
  /// it, so the release of the session releases the view. The Multitool
  /// registry of the session mounts the tool under the noun ``noun``, and
  /// the model reaches it with `tools.kanban.runKanban`. The model writes
  /// through this view with the actor of the session. A tunnel call of a
  /// person reaches the same graph, and the graph records the actor of its
  /// viewer. The actor name has the tag of the session, so the `undoChange`
  /// of one session does not reverse the change of another session in the
  /// same folder. The factory makes no tool when `tools.kanban` is off.
  ///
  /// - Parameter host: The host of the boards.
  /// - Returns: The factory.
  public static func sessionToolFactory(host: KanbanHost) -> SessionToolFactory {
    { context in
      guard context.tools.kanban.mountedOptions != nil else { return [] }
      let graph = try await host.session(
        workingDirectory: context.workingDirectory, actor: context.actorName)
      return [SessionOperationMount(noun: noun, tool: KanbanOperationTool(KanbanTool(graph: graph)))]
    }
  }
}
