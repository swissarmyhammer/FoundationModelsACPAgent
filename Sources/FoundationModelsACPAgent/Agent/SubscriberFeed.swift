import Synchronization

/// The number of events that the stream of one subscriber of a ``SubscriberFeed`` holds when the
/// subscriber does not read them, by default. It is at file level, because a generic type cannot
/// hold a stored static property.
private let subscriberFeedDefaultBufferLimit = 1024

/// The subscribers of one source of events. Each subscriber gets its own stream of each event
/// after it subscribed.
///
/// The buffer policy of each stream is `.bufferingNewest(bufferLimit)`. The source never waits
/// for a subscriber: a subscriber that falls behind by more than ``bufferLimit`` events loses
/// the oldest ones, and the feed calls its drop action for each lost event.
final class SubscriberFeed<Element: Sendable>: Sendable {
  /// The streams of the subscribers, by the number of each subscriber.
  private struct Subscribers {
    /// The number of the next subscriber.
    var nextNumber = 0

    /// The input of the stream of each subscriber, by its number.
    var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
  }

  /// The number of events that the stream of one subscriber holds when the subscriber does not
  /// read them, by default.
  static var defaultBufferLimit: Int {
    subscriberFeedDefaultBufferLimit
  }

  /// The number of events that the stream of one subscriber holds.
  let bufferLimit: Int

  /// The action for each event that a slow subscriber lost, for example a log line.
  private let dropped: @Sendable () -> Void

  /// The streams of the subscribers.
  private let subscribers = Mutex(Subscribers())

  /// Makes a feed with no subscriber.
  ///
  /// - Parameters:
  ///   - bufferLimit: The number of events that the stream of one subscriber holds.
  ///   - dropped: The action for each event that a slow subscriber lost.
  init(bufferLimit: Int = defaultBufferLimit, dropped: @escaping @Sendable () -> Void) {
    self.bufferLimit = bufferLimit
    self.dropped = dropped
  }

  /// Makes the stream of a new subscriber.
  ///
  /// - Returns: The stream. It gives each event after this call.
  func subscribe() -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Element.self, bufferingPolicy: .bufferingNewest(bufferLimit))
    let number = subscribers.withLock { subscribers in
      let number = subscribers.nextNumber
      subscribers.nextNumber += 1
      subscribers.continuations[number] = continuation
      return number
    }
    continuation.onTermination = { [weak self] _ in
      self?.unsubscribe(number)
    }
    return stream
  }

  /// Ends the stream of each subscriber, so a subscriber that reads it stops.
  deinit {
    for continuation in subscribers.withLock({ $0.continuations.values }) {
      continuation.finish()
    }
  }

  /// Gives events to each subscriber, in order. The call never waits.
  ///
  /// - Parameter events: The events.
  func publish(_ events: [Element]) {
    let continuations = subscribers.withLock { Array($0.continuations.values) }
    for continuation in continuations {
      for event in events {
        if case .dropped = continuation.yield(event) {
          dropped()
        }
      }
    }
  }

  /// Removes the stream of a subscriber that ended.
  ///
  /// - Parameter number: The number of the subscriber.
  private func unsubscribe(_ number: Int) {
    subscribers.withLock { _ = $0.continuations.removeValue(forKey: number) }
  }
}
