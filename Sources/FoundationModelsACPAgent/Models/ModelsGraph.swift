import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import GraphQL
import Graphiti

/// The `models` GraphQL endpoint (D183 (c), D100 (d)): the model of each slot
/// of the profile, the models that a slot can take, and the download size and
/// the disk state of each of them, for the Models pane of the settings.
///
/// - `Query.models` gives one row for each slot: `STANDARD`, `FLASH`,
///   `EMBEDDING` and `DECISION`. A row shows the first candidate of the slot
///   in the settings at the user level, its MTP drafter, its GGUF file, the
///   bytes of its download (model and drafter), the bytes on disk, the disk
///   state, and `configValue`: the reference in the encoding of a slot key.
///   `active` is the model that runs in the slot now, and `restartRequired`
///   tells that the settings differ from the launch of the running agent.
/// - `Query.choices(slot:)` gives the models that the slot can take, with the
///   same storage fields.
/// - `Subscription.changes(after:)` gives a change when the value of a slot
///   changes at the user level (`reason: SLOT`, `appliesAt: NEXT_LAUNCH`), or
///   when the disk state of a model of a slot changes (`reason: DISK`,
///   `appliesAt: NOW`). `Query.cursor` gives the cursor of the newest change.
///
/// A slot change applies at the next launch of the agent: the agent resolves
/// its profile one time, when it starts, and each session of the running
/// agent keeps the models of that launch.
///
/// The endpoint writes nothing. A client changes a slot through the
/// `settings` endpoint: `updateSetting(keyPath: ["profile", "<slot>"],
/// value: [configValue], level: USER)`.
///
/// No read of the endpoint downloads a model or loads a model. The agent
/// makes one endpoint over its settings store (``RoutedACPAgent/modelsEndpoint``).
/// A host that needs the endpoint before the agent exists, for example before
/// the first download, makes one with ``init(store:storage:launched:active:diskPollInterval:)``.
public final class ModelsGraph: GraphQLEndpoint, Sendable {
  /// The name of the endpoint.
  public static let endpointName = "models"

  /// The capacity of the change log.
  static let changeLogCapacity = 256

  /// The default time between two reads of the disk while a subscriber is
  /// open.
  public static let defaultDiskPollInterval: Duration = .seconds(30)

  /// The other names that a call can write.
  static let rules = GraphQLNameRules(
    aliases: GraphQLAliasTable(
      byType: [
        "Query": ["models": ["slots"], "choices": ["modelChoices"]],
        "Subscription": ["changes": ["modelChanges"]],
      ]))

  /// The name of the endpoint.
  public let name = endpointName

  /// The version of the schema.
  public let version = "1"

  /// The scope of the endpoint: the server.
  public let scope = GraphQLEndpointScope.server

  /// The reads of the endpoint.
  private let engine: ModelsEngine

  /// The change feed.
  private let feed: ModelsGraphChangeFeed

  /// Makes the endpoint.
  ///
  /// - Parameters:
  ///   - store: The settings store. The endpoint reads the user level.
  ///   - storage: The reader of the model storage. Give the cache folder and
  ///     the token provider of the model loads.
  ///   - launched: The profile section that the running agent resolved at its
  ///     launch, or `nil` (the default) when no agent runs yet.
  ///   - active: The model that runs in each slot, or none (the default).
  ///   - diskPollInterval: The time between two reads of the disk while a
  ///     subscriber is open.
  public init(
    store: SettingsStore, storage: any ModelStorageReading,
    launched: ProfileConfiguration? = nil, active: [ModelSlot: ModelRef] = [:],
    diskPollInterval: Duration = ModelsGraph.defaultDiskPollInterval
  ) {
    engine = ModelsEngine(store: store, storage: storage, launched: launched, active: active)
    feed = ModelsGraphChangeFeed(
      engine: engine, diskPollInterval: diskPollInterval, capacity: Self.changeLogCapacity)
  }

  /// The schema of the endpoint in SDL.
  public var schema: String {
    switch ModelsGraphAPI.builtSchema {
    case .success(let built): printSchema(schema: built.schema)
    case .failure: ""
    }
  }

  /// Runs one GraphQL document.
  ///
  /// - Parameters:
  ///   - query: The GraphQL document.
  ///   - variables: The values of the variables of the document.
  ///   - operationName: The operation of the document to run, or `nil`.
  ///   - viewer: The client that makes the call, or `nil` for the agent. Each
  ///     client sees the same models.
  /// - Returns: The GraphQL response as JSON text.
  /// - Throws: A fault that is not a GraphQL error.
  public func execute(
    query: String, variables: [String: Map], operationName: String?, viewer _: GraphQLViewer?
  ) async throws -> String {
    try await ModelsGraphAPI(schema: try ModelsGraphAPI.builtSchema.get()).respond(
      to: query, variables: variables, operationName: operationName, rules: Self.rules,
      formattedWith: .sortedKeys, context: context)
  }

  /// Starts one GraphQL subscription.
  ///
  /// - Parameters:
  ///   - query: The subscription document.
  ///   - variables: The values of the variables of the document.
  ///   - operationName: The operation of the document to run, or `nil`.
  ///   - viewer: The client that makes the call, or `nil` for the agent.
  /// - Returns: The GraphQL response of each event as JSON text.
  /// - Throws: A fault that is not a GraphQL error.
  public func subscribe(
    query: String, variables: [String: Map], operationName: String?, viewer _: GraphQLViewer?
  ) async throws -> AsyncThrowingStream<String, Error> {
    try await ModelsGraphAPI(schema: try ModelsGraphAPI.builtSchema.get()).subscribe(
      to: query, variables: variables, operationName: operationName, rules: Self.rules,
      formattedWith: .sortedKeys, context: context)
  }

  /// The context of one call.
  private var context: ModelsGraphContext {
    ModelsGraphContext(engine: engine, feed: feed)
  }
}

// MARK: - Context and resolver

/// The context of one call of the `models` endpoint.
struct ModelsGraphContext: GraphQLRunContext {
  /// The warnings of the call.
  let warnings = ResponseWarnings()

  /// The reads of the endpoint.
  let engine: ModelsEngine

  /// The change feed of the endpoint.
  let feed: ModelsGraphChangeFeed
}

/// The root resolver of the `models` endpoint.
struct ModelsGraphResolver: Sendable {
  /// `Query.models`.
  func models(context: ModelsGraphContext, arguments _: NoArguments) async throws
    -> [ModelsGraphSlotModel]
  {
    var rows: [ModelsGraphSlotModel] = []
    for slot in ModelSlot.allCases {
      let candidates = try await context.engine.candidates(of: slot)
      guard let first = candidates.first else {
        continue
      }
      rows.append(
        ModelsGraphSlotModel(
          slot: ModelsGraphSlot(slot),
          model: ModelsGraphModelFields(await context.engine.report(of: first)),
          candidates: candidates.map(\.graphQLMap),
          active: context.engine.active[slot]?.stringValue,
          restartRequired: context.engine.restartRequired(for: slot, candidates: candidates)))
    }
    return rows
  }

  /// `Query.choices(slot:)`.
  func choices(context: ModelsGraphContext, arguments: ModelsGraphChoicesArguments) async throws
    -> [ModelsGraphChoice]
  {
    var choices: [ModelsGraphChoice] = []
    for ref in try await context.engine.choices(of: arguments.slot.slot) {
      choices.append(ModelsGraphChoice(model: ModelsGraphModelFields(await context.engine.report(of: ref))))
    }
    return choices
  }

  /// `Query.cursor`.
  func cursor(context: ModelsGraphContext, arguments _: NoArguments) async -> String {
    await context.feed.log.cursor
  }

  /// `Subscription.changes(after:)`. The subscription counts as a
  /// subscriber of the disk watch while it is open.
  func changes(context: ModelsGraphContext, arguments: ModelsGraphChangesArguments) async
    -> ChangeLog<ModelsGraphChangeEvent>.Changes
  {
    let feed = context.feed
    _ = await feed.settingsWatch.value
    await feed.watch.subscribe()
    let inner = await feed.log.changes(after: arguments.after)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await entry in inner {
            continuation.yield(entry)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
        Task { await feed.watch.unsubscribe() }
      }
    }
  }
}

// MARK: - The API

/// The Graphiti API of the `models` endpoint.
struct ModelsGraphAPI: API {
  /// The schema, built one time.
  static let builtSchema = Result { try makeSchema() }

  /// The root resolver.
  let resolver = ModelsGraphResolver()

  /// The schema.
  let schema: Schema<ModelsGraphResolver, ModelsGraphContext>

  /// A type of the schema.
  typealias SchemaType = TypeComponent<ModelsGraphResolver, ModelsGraphContext>

  /// The text of the description of a slot change.
  static let appliesText =
    "A slot change applies at the next launch of the agent: the agent resolves its profile when it starts, and "
    + "each session of the running agent keeps the models of that launch."

  /// Builds the schema.
  private static func makeSchema() throws -> Schema<ModelsGraphResolver, ModelsGraphContext> {
    try SchemaBuilder(ModelsGraphResolver.self, ModelsGraphContext.self)
      .addToolkitScalars()
      .addToolkitIDScalar()
      .add {
        Enum(ModelsGraphSlot.self, as: "ModelSlot") {
          Value(.standard).description("The model of the main work: profile.standard.")
          Value(.flash).description("The small fast model: profile.flash.")
          Value(.embedding).description("The embedding model: profile.embedding.")
          Value(.decision).description("The model of the decisions of the router: profile.decision.")
        }
        .description("A model slot of the profile.")
        Enum(ModelsGraphDiskState.self, as: "ModelDiskState") {
          Value(.complete).description("Each file of the model and of its drafter is on disk.")
          Value(.partial).description("Some bytes are on disk, but not all of them.")
          Value(.missing).description("No byte is on disk. The first use downloads the model.")
        }
        .description("The disk state of a model and its drafter.")
        Enum(ModelsGraphChangeReason.self, as: "ModelChangeReason") {
          Value(.slot).description("The value of a slot in the settings changed.")
          Value(.disk).description("The files of a model on disk changed, for example a download ended.")
        }
        .description("Why the slots of a change changed.")
        Enum(ModelsGraphChangeApplies.self, as: "ModelChangeApplies") {
          Value(.nextLaunch).description(appliesText)
          Value(.now).description("Now: the change is a fact of the disk.")
        }
        .description("When a change takes effect.")
        slotModelType()
        choiceType()
        changeType()
      }
      .addQuery {
        Field("models", at: ModelsGraphResolver.models)
          .description(
            "One row for each slot: the first candidate of the slot in the settings at the USER level, and its "
              + "storage. No read downloads or loads a model.")
        Field("choices", at: ModelsGraphResolver.choices) {
          Argument("slot", at: \.slot).description("The slot.")
        }
        .description(
          "The models that the slot can take: its candidates in the settings, then the builtin candidates of "
            + "the slot. To select one, give [configValue] to the settings endpoint at the key path "
            + "[\"profile\", \"<slot>\"].")
        Field("cursor", at: ModelsGraphResolver.cursor)
          .description("The cursor of the newest change. Read the models, then subscribe after this cursor.")
      }
      .addSubscription {
        SubscriptionField(
          "changes",
          at: { (entry: ChangeLogEntry<ModelsGraphChangeEvent>) in
            { (_: ModelsGraphContext, _: ModelsGraphChangesArguments) async throws -> ModelsGraphChange in
              ModelsGraphChange(entry)
            }
          },
          atSub: ModelsGraphResolver.changes
        ) {
          Argument("after", at: \.after)
            .description("The cursor to resume after. None: the changes from now.")
        }
        .description(
          "A change when the value of a slot changes at the USER level (reason SLOT, appliesAt NEXT_LAUNCH), "
            + "or when the disk state of a model of a slot changes (reason DISK, appliesAt NOW). "
            + "RESYNC_REQUIRED ends it when a change after the cursor is lost: read the models and the cursor "
            + "again.")
      }
      .build()
  }

  /// The `SlotModel` type.
  private static func slotModelType() -> SchemaType {
    Type(ModelsGraphSlotModel.self, as: "SlotModel") {
      Field("slot", at: \.slot).description("The slot.")
      Field("repo", at: \.repo).description("The repository of the first candidate, or the location of a local model.")
      Field("path", at: \.path).description("The path inside the repository, or null.")
      Field("revision", at: \.revision).description("The pinned revision, or null.")
      Field("file", at: \.file).description("The GGUF file of the model, or null for a model that is not GGUF.")
      Field("drafter", at: \.drafter).description("The MTP drafter, or null.")
      Field("sizeBytes", at: \.sizeBytes)
        .description("The download size of the model and its drafter in bytes, or null when it is not known.")
      Field("presentBytes", at: \.presentBytes).description("The bytes of the model and its drafter on disk.")
      Field("state", at: \.state).description("The disk state of the model and its drafter.")
      Field("configValue", at: \.configValue)
        .description("The model in the encoding of a slot key of config.yaml: a string, or an object with a drafter.")
      Field("candidates", at: \.candidates).description("Each candidate of the slot in the settings, in order.")
      Field("active", at: \.active)
        .description("The model that runs in the slot now, or null when no agent runs.")
      Field("restartRequired", at: \.restartRequired)
        .description("True when the settings of the slot differ from the launch of the running agent. " + appliesText)
      Field("storageError", at: \.storageError)
        .description("The error of a storage read, or null. Then the size is null.")
    }
    .description("The model of one slot of the profile.")
  }

  /// The `ModelChoice` type.
  private static func choiceType() -> SchemaType {
    Type(ModelsGraphChoice.self, as: "ModelChoice") {
      Field("repo", at: \.repo).description("The repository, or the location of a local model.")
      Field("path", at: \.path).description("The path inside the repository, or null.")
      Field("revision", at: \.revision).description("The pinned revision, or null.")
      Field("file", at: \.file).description("The GGUF file of the model, or null for a model that is not GGUF.")
      Field("drafter", at: \.drafter).description("The MTP drafter, or null.")
      Field("sizeBytes", at: \.sizeBytes)
        .description("The download size of the model and its drafter in bytes, or null when it is not known.")
      Field("presentBytes", at: \.presentBytes).description("The bytes of the model and its drafter on disk.")
      Field("state", at: \.state).description("The disk state of the model and its drafter.")
      Field("configValue", at: \.configValue)
        .description("The model in the encoding of a slot key of config.yaml: a string, or an object with a drafter.")
      Field("storageError", at: \.storageError)
        .description("The error of a storage read, or null. Then the size is null.")
    }
    .description("One model that a slot can take.")
  }

  /// The `ModelChange` type.
  private static func changeType() -> SchemaType {
    Type(ModelsGraphChange.self, as: "ModelChange") {
      Field("cursor", at: \.cursor).description("The cursor that resumes the subscription after this change.")
      Field("at", at: \.at).description("The time of the change.")
      Field("added", at: \.added).description("None: the four slots are always there.")
      Field("changed", at: \.changed)
        .description("The slots that changed, by their key: standard, flash, embedding or decision.")
      Field("removed", at: \.removed).description("None.")
      Field("reason", at: \.reason).description("Why the slots changed.")
      Field("appliesAt", at: \.appliesAt).description("When the change takes effect.")
    }
    .description("One change of the models of the slots.")
  }
}
