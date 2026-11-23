import ACPImport
import CoreServices
import Foundation
import Logging
import Synchronization

/// The file system of the agent for ``ExternalSessionIndex``: the disk of the Mac, and one
/// FSEvents stream for each watch.
///
/// A directory read gets the size, the date and the kind of each item from the resource keys
/// of the read. It opens no file. A session file is read with `pread`
/// (`FileByteSource`), never mapped.
struct LocalExternalSessionFileSystem: ExternalSessionFileSystem {
  /// The resource keys of a directory read.
  private static let resourceKeys: [URLResourceKey] = [
    .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
  ]

  /// The items of one folder, with no item whose name starts with a dot.
  ///
  /// The read skips by name, not with `.skipsHiddenFiles`. That option also drops each item
  /// with the macOS hidden flag, and iCloud Drive sets that flag on each item under a dot
  /// folder: a root such as `~/.claude/projects` in a synced home gave no file.
  /// FoundationModelsRouter 2e74f703 fixed the same defect in its transcript discovery.
  ///
  /// - Parameter folder: The folder.
  /// - Returns: The items. No item when the folder does not exist.
  /// - Throws: The error of a folder that exists and that the read cannot read.
  func items(in folder: URL) throws -> [ExternalSessionDirectoryItem] {
    guard PathKind.of(folder) != .missing else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: Self.resourceKeys, options: []
    )
    .filter { !$0.lastPathComponent.hasPrefix(".") }
    .compactMap(Self.item(of:))
  }

  /// The item at one URL.
  ///
  /// - Parameter url: The URL.
  /// - Returns: The item, or `nil` when no item is at the URL.
  func item(at url: URL) -> ExternalSessionDirectoryItem? {
    guard PathKind.of(url) != .missing else { return nil }
    return Self.item(of: url)
  }

  /// Opens one file for `pread` reads.
  ///
  /// - Parameter file: The file.
  /// - Returns: The byte source of the file.
  /// - Throws: The error of the open.
  func openForReading(_ file: URL) throws -> any SessionByteSource {
    try FileByteSource(forReadingFrom: file)
  }

  /// The bytes of one small file of the agent.
  ///
  /// - Parameter file: The file.
  /// - Returns: The bytes, or `nil` when the file does not exist or cannot be read.
  func contents(of file: URL) -> Data? {
    try? Data(contentsOf: file)
  }

  /// Replaces the bytes of one file of the agent with an atomic write.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - data: The new bytes.
  /// - Throws: The error of the write.
  func replaceContents(of file: URL, with data: Data) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
  }

  /// Removes one file of the agent. A removal that fails for a file that exists is logged.
  ///
  /// - Parameter file: The file.
  func removeItem(at file: URL) {
    guard PathKind.of(file) != .missing else { return }
    do {
      try FileManager.default.removeItem(at: file)
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The index of external sessions cannot remove its index file.",
        metadata: ["path": "\(file.path)", "error": "\(error)"])
    }
  }

  /// Starts one FSEvents stream over the folders that exist, with file events.
  ///
  /// - Parameters:
  ///   - folders: The folders.
  ///   - latency: The latency of the stream.
  ///   - onChange: Called with the URLs of the items that changed.
  /// - Returns: The watch, or `nil` when no folder exists or the stream does not start.
  func watch(
    _ folders: [URL], latency: Duration, onChange: @escaping @Sendable ([URL]) -> Void
  ) -> (any ExternalSessionWatch)? {
    let existing = folders.filter { PathKind.of($0) == .directory }
    guard !existing.isEmpty else { return nil }
    return FSEventsExternalSessionWatch.start(existing, latency: latency, onChange: onChange)
  }

  /// The item of a URL from its resource values. An item whose values the read cannot get
  /// gives a warning with its path, and no item.
  ///
  /// - Parameter url: The URL.
  /// - Returns: The item, or `nil`.
  static func item(of url: URL) -> ExternalSessionDirectoryItem? {
    do {
      let values = try url.resourceValues(forKeys: Set(resourceKeys))
      let kind: ExternalSessionItemKind =
        values.isRegularFile == true ? .file : values.isDirectory == true ? .directory : .other
      return ExternalSessionDirectoryItem(
        url: url, kind: kind, size: Int64(values.fileSize ?? 0),
        modified: values.contentModificationDate ?? .distantPast)
    } catch {
      ACPAgentTelemetry.logger(.session).warning(
        "The index of external sessions cannot read the size or the date of an item. It skips the item.",
        metadata: ["path": "\(url.path)", "error": "\(error)"])
      return nil
    }
  }
}

/// One FSEvents stream with file events (the technique of `FSEventsFileEventSource` of
/// FoundationModelsCodeContext).
///
/// The stream calls its handler on a serial queue of its own. The stop of a stream runs on a
/// background queue, because the teardown of an FSEvents stream can block for seconds.
// swiftlint:disable:next no_unchecked_sendable  The stream reference is set one time in init and never changes; `stop()` gives it to the FSEvents teardown calls, which any thread can call.
final class FSEventsExternalSessionWatch: ExternalSessionWatch, @unchecked Sendable {
  /// The label of the queue of the stream callbacks.
  private static let queueLabel = "FoundationModelsACPAgent.external-sessions.fsevents"

  /// The flags of the stream: CF types in the callback, and one event for each file.
  private static let flags = FSEventStreamCreateFlags(
    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)

  /// The stream.
  private let stream: FSEventStreamRef

  /// True after the first stop. The stream is released one time only: a second stop, for
  /// example a second shutdown of the agent, does nothing.
  private let isStopped = Mutex(false)

  /// Makes the watch of a started stream.
  ///
  /// - Parameter stream: The stream.
  private init(stream: FSEventStreamRef) {
    self.stream = stream
  }

  /// Starts a stream over some folders.
  ///
  /// - Parameters:
  ///   - folders: The folders. Each exists.
  ///   - latency: The latency of the stream.
  ///   - onChange: Called with the URLs of the items that changed.
  /// - Returns: The watch, or `nil` when the stream does not start.
  static func start(
    _ folders: [URL], latency: Duration, onChange: @escaping @Sendable ([URL]) -> Void
  ) -> FSEventsExternalSessionWatch? {
    let box = Unmanaged.passRetained(FSEventsChangeBox(onChange: onChange))
    var context = FSEventStreamContext(
      version: 0, info: box.toOpaque(), retain: nil,
      release: { info in
        guard let info else { return }
        Unmanaged<FSEventsChangeBox>.fromOpaque(info).release()
      }, copyDescription: nil)
    let seconds = Double(latency.components.seconds)
      + Double(latency.components.attoseconds) / Double(Self.attosecondsPerSecond)
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault, callback, &context,
        folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        seconds, flags)
    else {
      box.release()
      ACPAgentTelemetry.logger(.session).warning(
        "The index of external sessions cannot start an FSEvents stream. A query reads the folders.")
      return nil
    }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: queueLabel))
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    return FSEventsExternalSessionWatch(stream: stream)
  }

  /// The number of attoseconds in one second.
  private static let attosecondsPerSecond: Int64 = 1_000_000_000_000_000_000

  /// The callback of each stream: gives the paths of the events to the change action of the
  /// box of the context. With `kFSEventStreamCreateFlagUseCFTypes`, the paths are a `CFArray`
  /// of `CFString`.
  private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let box = Unmanaged<FSEventsChangeBox>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self).compactMap { $0 as? String }
    box.onChange(paths.map { URL(fileURLWithPath: $0) })
  }

  /// Stops the stream when the watch goes away with no stop, for example the index of an agent
  /// that had no shutdown. The context of the stream holds the event input of the root, so
  /// with no stop the stream, its queue and the task of the events of the root stay.
  deinit {
    stop()
  }

  /// Stops the stream on a background queue, one time only.
  func stop() {
    let isFirstStop = isStopped.withLock { isStopped in
      defer { isStopped = true }
      return !isStopped
    }
    guard isFirstStop else { return }
    let box = FSEventsStreamBox(stream: stream)
    DispatchQueue.global(qos: .utility).async {
      FSEventStreamStop(box.stream)
      FSEventStreamInvalidate(box.stream)
      FSEventStreamRelease(box.stream)
    }
  }
}

/// The change action of a stream, across the C callback. The context of the stream retains it.
private final class FSEventsChangeBox: Sendable {
  /// The change action.
  let onChange: @Sendable ([URL]) -> Void

  /// Makes the box.
  ///
  /// - Parameter onChange: The change action.
  init(onChange: @escaping @Sendable ([URL]) -> Void) {
    self.onChange = onChange
  }
}

/// A stream reference that crosses into the teardown closure.
// swiftlint:disable:next no_unchecked_sendable  The reference never changes, and the FSEvents teardown calls are safe on any thread after the last use of the stream.
private struct FSEventsStreamBox: @unchecked Sendable {
  /// The stream.
  let stream: FSEventStreamRef
}
