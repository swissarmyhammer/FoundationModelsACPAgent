import ACPImport
import Foundation

/// The kind of one item of a directory read.
enum ExternalSessionItemKind: Sendable, Equatable {
  /// A regular file.
  case file

  /// A directory.
  case directory

  /// A different item, for example a symbolic link or a socket.
  case other
}

/// One item of a directory read: its URL, its kind, its size and its modification date. The
/// read gets these values from the resource keys of the directory. It opens no file.
struct ExternalSessionDirectoryItem: Sendable, Equatable {
  /// The URL of the item.
  let url: URL

  /// The kind of the item.
  let kind: ExternalSessionItemKind

  /// The size of the item, in bytes.
  let size: Int64

  /// The modification date of the item.
  let modified: Date

  /// The name of the item: the last component of its URL.
  var name: String { url.lastPathComponent }
}

/// A watch of some folders. The watch calls its change action until ``stop()``.
protocol ExternalSessionWatch: Sendable {
  /// Stops the watch. The change action gets no call after the stop.
  func stop()
}

/// The file system seam of ``ExternalSessionIndex``: each read and each write of the index
/// goes through it (D212, section 4). The agent gives ``LocalExternalSessionFileSystem``. A
/// test gives a fake that holds no file bytes and counts each call.
///
/// Each call can block on the disk. Thus the index calls it only in its worker tasks, never in
/// the isolation of the actor.
protocol ExternalSessionFileSystem: Sendable {
  /// The items of one folder, with no item whose name starts with a dot.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The items, in no order. No item when the folder does not exist.
  /// - Throws: The error of a folder that exists and that the read cannot read.
  func items(in folder: URL) throws -> [ExternalSessionDirectoryItem]

  /// The item at one URL.
  ///
  /// - Parameter url: The URL.
  /// - Returns: The item, or `nil` when no item is at the URL.
  func item(at url: URL) -> ExternalSessionDirectoryItem?

  /// Opens one file for bounded reads.
  ///
  /// - Parameter file: The file.
  /// - Returns: The byte source of the file.
  /// - Throws: The error of the open.
  func openForReading(_ file: URL) throws -> any SessionByteSource

  /// The bytes of one small file of the agent, for example an index file.
  ///
  /// - Parameter file: The file.
  /// - Returns: The bytes, or `nil` when the file does not exist or cannot be read.
  func contents(of file: URL) -> Data?

  /// Replaces the bytes of one file of the agent with an atomic replace. The call makes the
  /// folder of the file when it does not exist.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - data: The new bytes.
  /// - Throws: The error of the write.
  func replaceContents(of file: URL, with data: Data) throws

  /// Removes one file of the agent. A file that does not exist is not an error.
  ///
  /// - Parameter file: The file.
  func removeItem(at file: URL)

  /// Starts a watch of some folders and of each item under them.
  ///
  /// - Parameters:
  ///   - folders: The folders. A folder that does not exist is not watched.
  ///   - latency: The time that the watch joins the events of a burst into one call.
  ///   - onChange: Called with the URLs of the items that changed.
  /// - Returns: The watch, or `nil` when the file system cannot watch the folders.
  func watch(
    _ folders: [URL], latency: Duration, onChange: @escaping @Sendable ([URL]) -> Void
  ) -> (any ExternalSessionWatch)?
}

/// The time seam of ``ExternalSessionIndex``: the 30 s limits of a read and of a find. The agent
/// gives ``ContinuousExternalSessionClock``. A test gives a clock that it moves by hand.
protocol ExternalSessionClock: Sendable {
  /// The time now.
  var now: ContinuousClock.Instant { get }

  /// Suspends until a deadline.
  ///
  /// - Parameter deadline: The deadline.
  /// - Throws: `CancellationError` when the task is cancelled.
  func sleep(until deadline: ContinuousClock.Instant) async throws
}

/// The clock of the agent: the continuous clock of the system.
struct ContinuousExternalSessionClock: ExternalSessionClock {
  /// The time now on the continuous clock.
  var now: ContinuousClock.Instant { ContinuousClock.now }

  /// Suspends until a deadline of the continuous clock.
  ///
  /// - Parameter deadline: The deadline.
  /// - Throws: `CancellationError` when the task is cancelled.
  func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await ContinuousClock().sleep(until: deadline)
  }
}
