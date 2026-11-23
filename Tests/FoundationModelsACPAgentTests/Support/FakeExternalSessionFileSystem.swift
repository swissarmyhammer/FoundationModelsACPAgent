import ACPImport
import Foundation
import Synchronization

@testable import FoundationModelsACPAgent

/// A file system of Claude Code session files that holds no file bytes (D212, section 7).
///
/// Each file has a size, a date, an id, a working folder and a kind (automated, typed, or with
/// no `entrypoint`). A read makes the bytes of the requested range only: a head of two small
/// records, a tail of two small records, and line breaks between them. Thus a 60 MB file costs
/// no memory. The fake counts each directory read, each stat, each open and each read with its
/// range, and the most reads at one time.
final class FakeExternalSessionFileSystem: ExternalSessionFileSystem {
  /// Who started a session.
  enum SessionKind: Sendable {
    /// A program: `entrypoint` is `sdk-cli`.
    case automated

    /// A person: `entrypoint` is `cli`.
    case typed

    /// The records have no `entrypoint`.
    case noEntrypoint
  }

  /// One session file.
  struct File: Sendable {
    /// The id of the session: the name of the file with no extension.
    let id: String

    /// The working folder of the session.
    let cwd: String

    /// Who started the session.
    let kind: SessionKind

    /// The size of the file, in bytes.
    var size: Int64

    /// The modification date of the file.
    var modified: Date

    /// The number of the last change of the file. The last prompt of the tail holds it.
    var version = 0

    /// True when the tail records hold the working folder.
    let hasTailFolder: Bool

    /// The text of a `custom-title` record in the head, or `nil` for none.
    var headTitle: String?

    /// The text of a `summary` record in the tail, or `nil` for none.
    var tailSummary: String?

    /// The number of bytes of a last line of the tail with no record that the reader shows (a
    /// long tool result), or 0 for no such line.
    var longLastLineLength = 0

    /// The text of the first prompt of the session.
    var firstPrompt: String { "first prompt of \(id)" }

    /// The text of the last prompt of the session now.
    var lastPrompt: String { "last prompt of \(id) version \(version)" }

    /// The `entrypoint` member of a record, with its comma, or nothing.
    private var entrypoint: String {
      switch kind {
      case .automated: #""entrypoint":"sdk-cli","#
      case .typed: #""entrypoint":"cli","#
      case .noEntrypoint: ""
      }
    }

    /// The bytes of the head: a `queue-operation` record and a `user` record.
    var head: Data {
      let date = Self.text(of: modified.addingTimeInterval(-Self.sessionLength))
      let title = headTitle.map { #"{"type":"custom-title","customTitle":"\#($0)","sessionId":"\#(id)"}"# + "\n" }
      return Data(
        """
        {"type":"queue-operation","operation":"enqueue","timestamp":"\(date)","sessionId":"\(id)","content":"\(firstPrompt)"}
        {"type":"user","uuid":"u-\(id)","sessionId":"\(id)","timestamp":"\(date)","cwd":"\(cwd)",\(entrypoint)"message":{"role":"user","content":"\(firstPrompt)"}}

        """.utf8) + Data((title ?? "").utf8)
    }

    /// The bytes of the tail: an `assistant` record and a `last-prompt` record.
    var tail: Data {
      let folder = hasTailFolder ? #""cwd":"\#(cwd)","# : ""
      let summary = tailSummary.map { #"{"type":"summary","summary":"\#($0)","sessionId":"\#(id)"}"# + "\n" }
      let records = Data(
        """
        {"type":"assistant","uuid":"a-\(id)-\(version)","sessionId":"\(id)","timestamp":"\(Self.text(of: modified))",\(folder)"gitBranch":"main",\(entrypoint)"message":{"id":"m-\(version)","role":"assistant","content":[{"type":"text","text":"Done."}]}}
        {"type":"last-prompt","lastPrompt":"\(lastPrompt)","sessionId":"\(id)"}

        """.utf8) + Data((summary ?? "").utf8)
      guard longLastLineLength > 0 else { return records }
      return records + Data(repeating: UInt8(ascii: "x"), count: longLastLineLength) + [UInt8(ascii: "\n")]
    }

    /// The length of a session: the time from the first record to the last record.
    private static let sessionLength: TimeInterval = 3600

    /// The ISO 8601 text of a date, as Claude Code writes it.
    private static func text(of date: Date) -> String {
      date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// The bytes of a range of the file: the head, line breaks, and the tail.
    ///
    /// - Parameters:
    ///   - offset: The place of the first byte.
    ///   - length: The number of bytes.
    /// - Returns: The bytes. There are fewer than `length` bytes only at the end of the file.
    func bytes(offset: Int, length: Int) -> Data {
      let size = Int(self.size)
      let end = min(offset + length, size)
      guard end > offset else { return Data() }
      var data = Data(repeating: UInt8(ascii: "\n"), count: end - offset)
      Self.copy(head, at: 0, into: &data, range: offset..<end)
      let tail = self.tail
      Self.copy(tail, at: size - tail.count, into: &data, range: offset..<end)
      return data
    }

    /// Copies the part of a block that a range of the file holds.
    private static func copy(_ block: Data, at start: Int, into data: inout Data, range: Range<Int>) {
      let lower = max(start, range.lowerBound)
      let upper = min(start + block.count, range.upperBound)
      guard lower < upper else { return }
      data.replaceSubrange(
        (lower - range.lowerBound)..<(upper - range.lowerBound),
        with: block[(lower - start)..<(upper - start)])
    }
  }

  /// One read of a file.
  struct Read: Sendable, Equatable {
    /// The path of the file.
    let path: String

    /// The place of the first byte.
    let offset: Int

    /// The number of bytes that the reader asked for.
    let length: Int

    /// The size of the file at the read.
    let size: Int64

    /// True when the read covers the full file.
    var isFull: Bool { offset == 0 && Int64(length) >= size }
  }

  /// The state of the fake.
  private struct State {
    /// The session files, by their absolute path.
    var files: [String: File] = [:]

    /// The names of the items of each folder, by the absolute path of the folder.
    var folders: [String: Set<String>] = [:]

    /// The files of the agent, for example the index files, by their absolute path.
    var agentFiles: [String: Data] = [:]

    /// Each read, in order.
    var reads: [Read] = []

    /// The number of directory reads.
    var directoryReads = 0

    /// The number of opens of each file.
    var opens: [String: Int] = [:]

    /// The number of reads that run now, and the most at one time.
    var activeReads = 0
    var mostActiveReads = 0

    /// The change action of each watch, by its number.
    var watches: [Int: @Sendable ([URL]) -> Void] = [:]

    /// The action of the next directory read of each folder, by its path. It runs after the
    /// read made its result, outside the lock.
    var listingHooks: [String: @Sendable () -> Void] = [:]

    /// The action of the next read of each file, by its path. It runs before the read makes
    /// its bytes, outside the lock.
    var readHooks: [String: @Sendable () -> Void] = [:]

    /// The number of the next watch.
    var nextWatch = 0

    /// The number of calls of `stop()` of a watch.
    var watchStops = 0

    /// The action of the next read of each agent file, by path.
    var agentFileHooks: [String: @Sendable () -> Void] = [:]

    /// The action of the next start of a watch.
    var watchHook: (@Sendable () -> Void)?

    /// The action of the next stop of a watch.
    var watchStopHook: (@Sendable () -> Void)?
  }

  /// The state.
  private let state = Mutex(State())

  /// True when the fake gives a watch.
  private let givesWatches: Bool

  /// Makes an empty fake.
  ///
  /// - Parameter givesWatches: True when ``watch(_:latency:onChange:)`` gives a watch. False
  ///   gives no watch, as a remote volume.
  init(givesWatches: Bool = true) {
    self.givesWatches = givesWatches
  }

  // MARK: - The store

  /// Adds or replaces a session file, and each folder above it.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - url: The absolute URL of the file.
  func add(_ file: File, at url: URL) {
    state.withLock { state in
      state.files[url.path] = file
      var child = url
      while child.pathComponents.count > 1 {
        let parent = child.deletingLastPathComponent()
        let (inserted, _) = state.folders[parent.path, default: []].insert(child.lastPathComponent)
        guard inserted else { break }
        child = parent
      }
    }
  }

  /// Changes a session file: it grows, its date moves one second, and its version grows.
  ///
  /// - Parameters:
  ///   - url: The URL of the file.
  ///   - growth: The number of bytes that the file grows.
  ///   - edit: A change of the records of the file, for example a new tail record.
  func change(
    _ url: URL, growth: Int64, edit: @Sendable (inout File) -> Void = { _ in }
  ) {
    state.withLock { state in
      state.files[url.path]?.size += growth
      state.files[url.path]?.modified.addTimeInterval(1)
      state.files[url.path]?.version += 1
      if var file = state.files[url.path] {
        edit(&file)
        state.files[url.path] = file
      }
    }
  }

  /// Sets the action of the next directory read of a folder. The action runs one time, after
  /// the read made its result: a test can change the store or hold the read there.
  ///
  /// - Parameters:
  ///   - folder: The folder.
  ///   - action: The action.
  func setListingHook(for folder: URL, _ action: @escaping @Sendable () -> Void) {
    state.withLock { $0.listingHooks[folder.path] = action }
  }

  /// Sets the action of the next read of a file. The action runs one time, before the read
  /// makes its bytes: a test can change the store or hold the read there.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - action: The action.
  func setReadHook(for file: URL, _ action: @escaping @Sendable () -> Void) {
    state.withLock { $0.readHooks[file.path] = action }
  }

  /// The number of watches that did not stop.
  var watchCount: Int { state.withLock { $0.watches.count } }

  /// The number of calls of `stop()` of a watch, also a second call for one watch.
  var watchStopCount: Int { state.withLock { $0.watchStops } }

  /// Sets the action of the next read of a file of the agent, for example the index file. The
  /// action runs one time, before the read: a test can hold the load of the index file there.
  ///
  /// - Parameters:
  ///   - file: The file.
  ///   - action: The action.
  func setAgentFileHook(for file: URL, _ action: @escaping @Sendable () -> Void) {
    state.withLock { $0.agentFileHooks[file.path] = action }
  }

  /// Sets the action of the next stop of a watch. The action runs one time, after the stop.
  ///
  /// - Parameter action: The action.
  func setWatchStopHook(_ action: @escaping @Sendable () -> Void) {
    state.withLock { $0.watchStopHook = action }
  }

  /// Sets the action of the next start of a watch. The action runs one time. The index starts
  /// the watch of a root after it installed the entries of the index file.
  ///
  /// - Parameter action: The action.
  func setWatchHook(_ action: @escaping @Sendable () -> Void) {
    state.withLock { $0.watchHook = action }
  }

  /// Removes a session file.
  ///
  /// - Parameter url: The URL of the file.
  func removeFile(_ url: URL) {
    state.withLock { state in
      state.files[url.path] = nil
      state.folders[url.deletingLastPathComponent().path]?.remove(url.lastPathComponent)
    }
  }

  /// Sets the bytes of a file of the agent, for example an index file.
  ///
  /// - Parameters:
  ///   - data: The bytes.
  ///   - url: The URL of the file.
  func setAgentFile(_ data: Data, at url: URL) {
    state.withLock { $0.agentFiles[url.path] = data }
  }

  /// Gives a batch of events to each watch, as FSEvents does.
  ///
  /// - Parameter urls: The URLs of the changed items.
  func emit(_ urls: [URL]) {
    for watch in state.withLock({ Array($0.watches.values) }) {
      watch(urls)
    }
  }

  // MARK: - The counts

  /// Each read, in order.
  var reads: [Read] { state.withLock { $0.reads } }

  /// The number of reads.
  var readCount: Int { state.withLock { $0.reads.count } }

  /// The number of directory reads.
  var directoryReadCount: Int { state.withLock { $0.directoryReads } }

  /// The number of opens of each file, by its path.
  var opens: [String: Int] { state.withLock { $0.opens } }

  /// The total number of opens.
  var openCount: Int { state.withLock { $0.opens.values.reduce(0, +) } }

  /// The most reads at one time.
  var mostActiveReads: Int { state.withLock { $0.mostActiveReads } }

  /// The bytes of a file of the agent.
  ///
  /// - Parameter url: The URL of the file.
  /// - Returns: The bytes, or `nil`.
  func agentFile(at url: URL) -> Data? {
    state.withLock { $0.agentFiles[url.path] }
  }

  // MARK: - ExternalSessionFileSystem

  func items(in folder: URL) throws -> [ExternalSessionDirectoryItem] {
    let (items, hook) = state.withLock { state in
      state.directoryReads += 1
      let items = (state.folders[folder.path] ?? []).filter { !$0.hasPrefix(".") }.map { name in
        Self.item(at: folder.appendingPathComponent(name), in: state)
      }
      return (items, state.listingHooks.removeValue(forKey: folder.path))
    }
    hook?()
    return items
  }

  func item(at url: URL) -> ExternalSessionDirectoryItem? {
    state.withLock { state in
      guard state.files[url.path] != nil || state.folders[url.path] != nil else { return nil }
      return Self.item(at: url, in: state)
    }
  }

  func openForReading(_ file: URL) throws -> any SessionByteSource {
    let found = state.withLock { state -> File? in
      state.opens[file.path, default: 0] += 1
      return state.files[file.path]
    }
    guard let found else { throw CocoaError(.fileNoSuchFile) }
    return FakeByteSource(file: found, path: file.path, fileSystem: self)
  }

  func contents(of file: URL) -> Data? {
    let hook = state.withLock { $0.agentFileHooks.removeValue(forKey: file.path) }
    hook?()
    return agentFile(at: file)
  }

  func replaceContents(of file: URL, with data: Data) throws {
    setAgentFile(data, at: file)
  }

  func removeItem(at file: URL) {
    state.withLock { $0.agentFiles[file.path] = nil }
  }

  func watch(
    _ folders: [URL], latency: Duration, onChange: @escaping @Sendable ([URL]) -> Void
  ) -> (any ExternalSessionWatch)? {
    let hook = state.withLock { state in
      defer { state.watchHook = nil }
      return state.watchHook
    }
    hook?()
    guard givesWatches else { return nil }
    let number = state.withLock { state in
      let number = state.nextWatch
      state.nextWatch += 1
      state.watches[number] = onChange
      return number
    }
    return FakeWatch { [weak self] in
      let hook = self?.state.withLock { state in
        state.watchStops += 1
        _ = state.watches.removeValue(forKey: number)
        defer { state.watchStopHook = nil }
        return state.watchStopHook
      }
      hook?()
    }
  }

  // MARK: - The reads

  /// Records the start of a read, after the action of the next read of the file.
  fileprivate func beginRead(_ read: Read) {
    state.withLock { $0.readHooks.removeValue(forKey: read.path) }?()
    state.withLock { state in
      state.reads.append(read)
      state.activeReads += 1
      state.mostActiveReads = max(state.mostActiveReads, state.activeReads)
    }
  }

  /// Records the end of a read.
  fileprivate func endRead() {
    state.withLock { $0.activeReads -= 1 }
  }

  /// The item at a URL of the state.
  private static func item(at url: URL, in state: State) -> ExternalSessionDirectoryItem {
    guard let file = state.files[url.path] else {
      return ExternalSessionDirectoryItem(url: url, kind: .directory, size: 0, modified: .distantPast)
    }
    return ExternalSessionDirectoryItem(url: url, kind: .file, size: file.size, modified: file.modified)
  }
}

/// The byte source of one fake file: it makes the bytes of each range, and records the read.
private struct FakeByteSource: SessionByteSource {
  /// The file at the open.
  let file: FakeExternalSessionFileSystem.File

  /// The path of the file.
  let path: String

  /// The fake that records the reads.
  let fileSystem: FakeExternalSessionFileSystem

  var size: Int { Int(file.size) }

  func read(offset: Int, length: Int) throws -> Data {
    fileSystem.beginRead(
      FakeExternalSessionFileSystem.Read(path: path, offset: offset, length: length, size: file.size))
    defer { fileSystem.endRead() }
    return file.bytes(offset: offset, length: length)
  }
}

/// A watch of the fake: its stop removes its change action.
private struct FakeWatch: ExternalSessionWatch {
  /// Removes the change action.
  let onStop: @Sendable () -> Void

  func stop() {
    onStop()
  }
}
