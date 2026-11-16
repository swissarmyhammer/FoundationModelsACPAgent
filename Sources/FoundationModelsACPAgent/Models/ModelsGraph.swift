import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import GraphQL
import Graphiti

/// The `models` GraphQL endpoint (D183 (c), D100 (d), ACPA-21, D189): the
/// builtin profiles that the user can select, the model of each slot of the
/// selected profile, and the download size, the disk state and the fit of
/// each of them, for the Models pane of the settings.
///
/// - `Query.profiles` gives one row for each builtin profile, in the order of
///   the list. A row shows the name, the description, if the profile is
///   selected and if it is active, the model of each slot, the download size
///   and the bytes on disk of its different models (each counted one time),
///   its disk state, and its fit against the memory budget of the machine.
/// - `Query.models` gives one row for each slot of the selected profile:
///   `STANDARD`, `FLASH`, `EMBEDDING` and `DECISION`. It is read-only.
/// - `Subscription.changes(after:)` gives a change when `profile.preset`
///   changes at the user level (`reason: PROFILE`, `appliesAt: NEXT_LAUNCH`),
///   or when the disk state of a model of a builtin profile changes
///   (`reason: DISK`, `appliesAt: NOW`). `Query.cursor` gives the cursor of
///   the newest change.
///
/// A profile change applies at the next launch of the agent: the agent
/// resolves its profile one time, when it starts, and each session of the
/// running agent keeps the models of that launch.
///
/// The endpoint writes nothing. A client selects a profile through the
/// `settings` endpoint: `updateSetting(keyPath: ["profile", "preset"],
/// value: "<name>", level: USER)`.
///
/// No read of the endpoint downloads a model or loads a model. The agent
/// makes one endpoint over its settings store (``RoutedACPAgent/modelsEndpoint``).
/// A host that needs the endpoint before the agent exists, for example before
/// the first download, makes one with
/// ``init(store:storage:launched:active:fitEstimator:diskPollInterval:)``.
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
        "Query": ["models": ["slots"], "profiles": ["modelProfiles", "presets"]],
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
  ///   - fitEstimator: The source of the fit estimate of each profile, or
  ///     `nil` (the default) when the fit is not known: then each profile
  ///     has the fit `UNKNOWN`. A host gives the estimate of its router
  ///     also before the agent exists.
  ///   - diskPollInterval: The time between two reads of the disk while a
  ///     subscriber is open.
  public init(
    store: SettingsStore, storage: any ModelStorageSource,
    launched: ProfileConfiguration? = nil, active: [ModelSlot: ModelRef] = [:],
    fitEstimator: (any ProfileFitEstimating)? = nil,
    diskPollInterval: Duration = ModelsGraph.defaultDiskPollInterval
  ) {
    engine = ModelsEngine(
      store: store, storage: storage, launched: launched, active: active,
      fitEstimator: fitEstimator)
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

  /// `Query.profiles`.
  func profiles(context: ModelsGraphContext, arguments _: NoArguments) async throws
    -> [ModelsGraphProfile]
  {
    try await context.engine.profiles()
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

  /// The text of the description of a profile change.
  static let appliesText =
    "A profile change applies at the next launch of the agent: the agent resolves its profile when it starts, "
    + "and each session of the running agent keeps the models of that launch."

  /// Builds the schema.
  private static func makeSchema() throws -> Schema<ModelsGraphResolver, ModelsGraphContext> {
    try SchemaBuilder(ModelsGraphResolver.self, ModelsGraphContext.self)
      .addToolkitScalars()
      .addToolkitIDScalar()
      .add {
        Enum(ModelsGraphSlot.self, as: "ModelSlot") {
          Value(.standard).description("The model of the main work.")
          Value(.flash).description("The fast model.")
          Value(.embedding).description("The embedding model.")
          Value(.decision).description("The model of the decisions of the router.")
        }
        .description("A model slot of the profile.")
        Enum(ModelsGraphDiskState.self, as: "ModelDiskState") {
          Value(.complete).description("Each file of the model and of its drafter is on disk.")
          Value(.partial).description("Some bytes are on disk, but not all of them.")
          Value(.missing).description("No byte is on disk. The first use downloads the model.")
        }
        .description("The disk state of a model and its drafter.")
        Enum(ModelsGraphProfileFit.self, as: "ProfileFit") {
          Value(.fits).description("The profile fits the memory budget of this machine.")
          Value(.doesNotFit).description("The profile does not fit the memory budget of this machine.")
          Value(.unknown).description("The fit is not known: the endpoint has no fit estimate.")
        }
        .description("The fit of a profile against the memory budget of the machine.")
        Enum(ModelsGraphChangeReason.self, as: "ModelChangeReason") {
          Value(.profile).description("The value of profile.preset in the settings changed.")
          Value(.disk).description("The files of a model on disk changed, for example a download ended.")
        }
        .description("Why the slots of a change changed.")
        Enum(ModelsGraphChangeApplies.self, as: "ModelChangeApplies") {
          Value(.nextLaunch).description(appliesText)
          Value(.now).description("Now: the change is a fact of the disk.")
        }
        .description("When a change takes effect.")
        slotModelType()
        profileModelType()
        profileType()
        changeType()
      }
      .addQuery {
        Field("profiles", at: ModelsGraphResolver.profiles)
          .description(
            "One row for each builtin profile, in order, from the largest to the smallest. To select one, give "
              + "its name to the settings endpoint: updateSetting(keyPath: [\"profile\", \"preset\"], "
              + "value: \"<name>\", level: USER). No read downloads or loads a model.")
        Field("models", at: ModelsGraphResolver.models)
          .description(
            "One row for each slot of the profile that profile.preset selects at the USER level: the first "
              + "candidate of the slot, and its storage. Read-only. No read downloads or loads a model.")
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
          "A change when profile.preset changes at the USER level (reason PROFILE, appliesAt NEXT_LAUNCH), "
            + "or when the disk state of a model of a builtin profile changes (reason DISK, appliesAt NOW). "
            + "Read the profiles and the models again. "
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
      Field("candidates", at: \.candidates).description("Each candidate of the slot in the profile, in order.")
      Field("active", at: \.active)
        .description("The model that runs in the slot now, or null when no agent runs.")
      Field("restartRequired", at: \.restartRequired)
        .description("True when the model of the slot differs from the launch of the running agent. " + appliesText)
      Field("storageError", at: \.storageError)
        .description("The error of a storage read, or null. Then the size is null.")
    }
    .description("The model of one slot of the selected profile.")
  }

  /// The `ProfileModel` type.
  private static func profileModelType() -> SchemaType {
    Type(ModelsGraphProfileModel.self, as: "ProfileModel") {
      Field("slot", at: \.slot).description("The slot.")
      Field("repo", at: \.repo).description("The repository, or the location of a local model.")
      Field("path", at: \.path).description("The path inside the repository, or null.")
      Field("revision", at: \.revision).description("The pinned revision, or null.")
      Field("file", at: \.file).description("The GGUF file of the model, or null for a model that is not GGUF.")
      Field("drafter", at: \.drafter).description("The MTP drafter, or null.")
      Field("sizeBytes", at: \.sizeBytes)
        .description("The download size of the model and its drafter in bytes, or null when it is not known.")
      Field("presentBytes", at: \.presentBytes).description("The bytes of the model and its drafter on disk.")
      Field("state", at: \.state).description("The disk state of the model and its drafter.")
      Field("storageError", at: \.storageError)
        .description("The error of a storage read, or null. Then the size is null.")
    }
    .description("The model of one slot of a profile: the first candidate of the slot.")
  }

  /// The `ModelProfile` type.
  private static func profileType() -> SchemaType {
    Type(ModelsGraphProfile.self, as: "ModelProfile") {
      Field("name", at: \.name).description("The name: the value of profile.preset that selects the profile.")
      Field("description", at: \.description).description("One sentence about the profile.")
      Field("selected", at: \.selected).description("True when profile.preset at the USER level names the profile.")
      Field("active", at: \.active)
        .description("True when the running agent launched with the profile. False when no agent runs.")
      Field("restartRequired", at: \.restartRequired)
        .description("True when the profile is selected and the running agent launched with a different one. " + appliesText)
      Field("models", at: \.models).description("The model of each slot.")
      Field("downloadBytes", at: \.downloadBytes)
        .description(
          "The download size of the different models and drafters of the profile in bytes, each model counted one "
            + "time, or null when a size is not known.")
      Field("presentBytes", at: \.presentBytes)
        .description("The bytes of the different models and drafters of the profile on disk.")
      Field("state", at: \.state)
        .description("COMPLETE when each model is complete, MISSING when no byte is on disk, else PARTIAL.")
      Field("fit", at: \.fit).description("The fit of the profile against the memory budget of this machine.")
      Field("requiredBytes", at: \.requiredBytes)
        .description("The memory that the profile needs in bytes, or null when the profile does not fit.")
      Field("budgetBytes", at: \.budgetBytes)
        .description("The memory budget of this machine in bytes, or null when no estimate ran.")
      Field("fitError", at: \.fitError)
        .description("Why the profile does not fit: the budget is too small, or a model could not be sized. Null when it fits.")
    }
    .description("One builtin profile: the models of the four slots, which the user selects together.")
  }

  /// The `ModelChange` type.
  private static func changeType() -> SchemaType {
    Type(ModelsGraphChange.self, as: "ModelChange") {
      Field("cursor", at: \.cursor).description("The cursor that resumes the subscription after this change.")
      Field("at", at: \.at).description("The time of the change.")
      Field("added", at: \.added).description("None: the four slots and the builtin profiles are always there.")
      Field("changed", at: \.changed)
        .description(
          "The slots of the selected profile that changed, by their key: standard, flash, embedding or decision. "
            + "A DISK change of a model of an other profile names no slot.")
      Field("removed", at: \.removed).description("None.")
      Field("reason", at: \.reason).description("Why the slots changed.")
      Field("appliesAt", at: \.appliesAt).description("When the change takes effect.")
    }
    .description("One change of the models of the slots.")
  }
}
