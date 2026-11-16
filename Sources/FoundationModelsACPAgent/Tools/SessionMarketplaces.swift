import Foundation
import FoundationModelsExtras
import FoundationModelsSkills
import Synchronization

/// A marketplace store that a session starts and stops. `MarketplaceStore`
/// of Extras conforms; a test gives a store that records its calls.
public protocol SessionMarketplaceStore: MarketplaceLayerProviding {
  /// Fetches each source when necessary, and serves the layers.
  func start() async

  /// Stops the update loop of the store.
  func stop() async
}

extension MarketplaceStore: SessionMarketplaceStore {}

/// The marketplace registry of the agent, and the list that a session reads
/// after a change of it.
public struct MarketplaceMount: Sendable {
  /// The one marketplace registry of the agent
  /// (``RoutedACPAgent/marketplaceRegistry``).
  public let registry: MarketplaceRegistry

  /// The marketplace list of the session after a change: the merged
  /// `tools.skills.marketplaces` of its working directory.
  public let sources: @Sendable () async throws -> [MarketplaceSource]

  /// Makes a mount.
  ///
  /// - Parameters:
  ///   - registry: The marketplace registry of the agent.
  ///   - sources: Gives the list of the session after a change.
  public init(
    registry: MarketplaceRegistry,
    sources: @escaping @Sendable () async throws -> [MarketplaceSource]
  ) {
    self.registry = registry
    self.sources = sources
  }
}

/// The marketplace layers of one session (D190).
///
/// The skills registry and the agent registry of the session read their
/// marketplace layers through this provider. It serves the layers of one
/// started store. On each change of the marketplace registry of the agent,
/// it makes a new store from the new list, starts it, serves its layers,
/// and stops the old store (the rule of Extras: a store has a fixed list).
/// Then it tells each consumer to read the layers again, so the skills and
/// the agents of a running session follow the change.
///
/// An empty list has no store and no layer.
public final class SessionMarketplaces: MarketplaceLayerProviding, Sendable {
  /// Makes the store of a list that is not empty.
  typealias MakeStore = @Sendable ([MarketplaceSource]) -> any SessionMarketplaceStore

  /// The mutable state.
  private struct State {
    /// The store whose layers this provider serves, or `nil`.
    var store: (any SessionMarketplaceStore)?

    /// The task that forwards the updates of ``store``.
    var forward: Task<Void, Never>?

    /// The task that follows the registry.
    var follow: Task<Void, Never>?

    /// The consumers of ``layerUpdates``.
    var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// True after ``stop()``.
    var stopped = false
  }

  /// The state.
  private let state = Mutex(State())

  /// Makes the store of a list.
  private let makeStore: MakeStore

  /// Makes a provider with no store.
  ///
  /// - Parameter makeStore: Makes the store of a list that is not empty.
  init(makeStore: @escaping MakeStore) {
    self.makeStore = makeStore
  }

  /// The layers of the current store, lowest precedence first.
  ///
  /// - Returns: The layers.
  public func marketplaceLayers() -> [MarketplaceLayer] {
    state.withLock { $0.store }?.marketplaceLayers() ?? []
  }

  /// One value for each change of the layers: an update of the current
  /// store, or a swap of the store.
  public var layerUpdates: AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    continuation.onTermination = { [weak self] _ in
      _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
    }
    let stopped = state.withLock { state in
      if !state.stopped {
        state.subscribers[id] = continuation
      }
      return state.stopped
    }
    if stopped {
      continuation.finish()
    }
    return stream
  }

  /// Serves the layers of a new store of `sources`, and stops the old
  /// store. An empty list serves no layer.
  ///
  /// - Parameter sources: The new list.
  func replace(with sources: [MarketplaceSource]) async {
    let new = sources.isEmpty ? nil : makeStore(sources)
    await new?.start()
    let updates = new?.layerUpdates
    let swapped = state.withLock { state -> (any SessionMarketplaceStore)?? in
      guard !state.stopped else {
        return nil
      }
      let old = state.store
      state.forward?.cancel()
      state.store = new
      state.forward = updates.map { updates in
        Task { [weak self] in
          for await _ in updates {
            self?.publish()
          }
        }
      }
      return .some(old)
    }
    guard let old = swapped else {
      await new?.stop()
      return
    }
    await old?.stop()
    publish()
  }

  /// Follows the changes of the marketplace registry: each change replaces
  /// the store with a store of the list that `sources` gives. A list that
  /// does not load keeps the current store.
  ///
  /// - Parameters:
  ///   - changes: The change stream of the registry. The caller takes it
  ///     before it reads the first list, so no change is lost.
  ///   - sources: Gives the list after a change.
  func follow(
    _ changes: AsyncStream<MarketplaceRegistryChange>,
    sources: @escaping @Sendable () async throws -> [MarketplaceSource]
  ) {
    let task = Task { [weak self] in
      for await _ in changes {
        guard let list = try? await sources() else {
          continue
        }
        await self?.replace(with: list)
      }
    }
    let stopped = state.withLock { state in
      state.follow?.cancel()
      state.follow = task
      return state.stopped
    }
    if stopped {
      task.cancel()
    }
  }

  /// Stops the follow of the registry and the current store, and ends each
  /// stream of ``layerUpdates``. The consumers keep their last layers.
  public func stop() async {
    let (store, tasks, subscribers) = state.withLock { state in
      state.stopped = true
      let taken = (state.store, [state.forward, state.follow], Array(state.subscribers.values))
      state.store = nil
      state.forward = nil
      state.follow = nil
      state.subscribers = [:]
      return taken
    }
    tasks.forEach { $0?.cancel() }
    subscribers.forEach { $0.finish() }
    await store?.stop()
  }

  /// Tells each consumer to read the layers again.
  private func publish() {
    for subscriber in state.withLock({ Array($0.subscribers.values) }) {
      subscriber.yield()
    }
  }
}
