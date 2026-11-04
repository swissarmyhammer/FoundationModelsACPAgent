import Foundation

// MARK: - The script file of the scripted stub model
//
// `ACP_AGENT_STUB_SCRIPT` names a JSON file. The file tells the stub model
// what each session of a spawned `acp-agent` says and calls:
//
//     { "sessions": [
//         { "match": { "promptContains": "<text>" },
//           "passes": [ [ <step>, ... ], [ <step>, ... ] ] } ] }
//
// A step has one key:
//
//     { "text": "<delta>" }
//     { "reasoning": "<text>" }
//     { "toolCall": { "name": "<tool>", "arguments": { ... } } }
//     { "gate": "<path>" }
//     { "elicit": "<message>" }
//     { "permission": "<title>" }
//
// The `elicit` step asks the user a form question with one required text
// field named `answer`, and waits. The answer text is the output of the
// call, and the pass goes on. A decline or a cancel ends the pass with a
// clear text. The step plays as a `runCode` call, so a session whose agent
// has no `runCode` tool cannot ask.
//
// The `permission` step sends `session/request_permission` to the client
// with the title, and two options: allow once and reject once. It waits for
// the outcome. A selected option lets the pass go on, and the script decides
// what a reject means. A cancelled outcome ends the pass with a clear text,
// as a cancel of an `elicit` step does. The request names the session of the
// run, so a child run asks under its own session id, one time. A
// `session/cancel` of that session ends the request. The step plays as a
// `runCode` call too, and the client must answer form questions.
//
// The steps are the ``ScriptedPassStep`` values of the in-process tests.
// A bad file is an error of ``ScriptedStubScriptError``. It is never a
// silent echo.

/// The sessions of a scripted stub model.
public struct ScriptedStubScript: Sendable, Equatable {
  /// One session of the script.
  public struct Session: Sendable, Equatable {
    /// The text that the first prompt of a session must contain to
    /// match this entry.
    public let promptContains: String

    /// The passes of the session, in order. A pass is one model call.
    public let passes: [[ScriptedPassStep]]

    /// Makes a session entry.
    ///
    /// - Parameters:
    ///   - promptContains: The text the first prompt must contain.
    ///   - passes: The passes of the session, in order.
    public init(promptContains: String, passes: [[ScriptedPassStep]]) {
      self.promptContains = promptContains
      self.passes = passes
    }
  }

  /// The session entries, in file order.
  public let sessions: [Session]

  /// Makes a script.
  ///
  /// - Parameter sessions: The session entries, in order.
  public init(sessions: [Session]) {
    self.sessions = sessions
  }

  /// The passes of the first entry that matches `prompt`.
  ///
  /// - Parameter prompt: The first prompt of a session.
  /// - Returns: The passes, or `nil` when no entry matches.
  public func passes(forFirstPrompt prompt: String) -> [[ScriptedPassStep]]? {
    sessions.first { prompt.contains($0.promptContains) }?.passes
  }

  /// Reads and parses the script file at `path`.
  ///
  /// - Parameter path: The path of the JSON file.
  /// - Returns: The script.
  /// - Throws: ``ScriptedStubScriptError`` when the file cannot be read or
  ///   is not a valid script.
  public static func load(fromPath path: String) throws -> ScriptedStubScript {
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw ScriptedStubScriptError.unreadable(path: path, reason: error.localizedDescription)
    }
    do {
      return try parse(data)
    } catch let error as ScriptedStubScriptError {
      throw error.reading(path: path)
    }
  }

  /// Parses the bytes of a script file.
  ///
  /// - Parameter data: The JSON of the file.
  /// - Returns: The script.
  /// - Throws: ``ScriptedStubScriptError`` when the bytes are not JSON, or
  ///   are not a valid script.
  public static func parse(_ data: Data) throws -> ScriptedStubScript {
    let root: Any
    do {
      root = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ScriptedStubScriptError.invalid(
        location: "file", problem: "it is not JSON (\(error.localizedDescription))", path: nil)
    }
    let object = try ScriptReader.object(root, at: "file", allowing: ["sessions"])
    let sessions = try ScriptReader.array(object["sessions"], at: "sessions")
    return ScriptedStubScript(
      sessions: try sessions.enumerated().map { index, session in
        try ScriptReader.session(session, at: "sessions[\(index)]")
      })
  }
}

/// The reason that a script file is refused.
public enum ScriptedStubScriptError: Error, Equatable, CustomStringConvertible, LocalizedError {
  /// The file cannot be read.
  case unreadable(path: String, reason: String)

  /// The file was read, and it is not a valid script.
  case invalid(location: String, problem: String, path: String?)

  /// The error with the path of the file that it came from.
  ///
  /// - Parameter path: The path of the script file.
  /// - Returns: The same error, with `path`.
  func reading(path: String) -> ScriptedStubScriptError {
    switch self {
    case .unreadable:
      self
    case .invalid(let location, let problem, _):
      .invalid(location: location, problem: problem, path: path)
    }
  }

  /// The message of the error: the file, the place and the problem.
  public var description: String {
    switch self {
    case .unreadable(let path, let reason):
      "The stub script file \(path) cannot be read: \(reason)"
    case .invalid(let location, let problem, let path):
      "The stub script file\(path.map { " \($0)" } ?? "") is not valid at \(location): \(problem)"
    }
  }

  /// The message that a `LocalizedError` shows, the same as ``description``.
  public var errorDescription: String? {
    description
  }
}

/// Reads the parts of a script file out of the values of `JSONSerialization`.
/// Each read names the place of the value, so an error tells where to look.
private enum ScriptReader {
  /// The key of a step that is a text delta.
  static let textKey = "text"

  /// The key of a step that is a reasoning text.
  static let reasoningKey = "reasoning"

  /// The key of a step that is a tool call.
  static let toolCallKey = "toolCall"

  /// The key of a step that is a gate.
  static let gateKey = "gate"

  /// The key of a step that is a question to the user.
  static let elicitKey = "elicit"

  /// The key of a step that is a request for permission.
  static let permissionKey = "permission"

  /// Fails with an invalid-script error.
  private static func invalid(_ location: String, _ problem: String) -> ScriptedStubScriptError {
    .invalid(location: location, problem: problem, path: nil)
  }

  /// Reads `value` as an object. When `allowed` is not `nil`, the object has
  /// no key outside it.
  static func object(_ value: Any?, at location: String, allowing allowed: Set<String>?) throws
    -> [String: Any]
  {
    guard let object = value as? [String: Any] else {
      throw invalid(location, "a JSON object is needed")
    }
    if let allowed, let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw invalid(location, "the key \"\(unknown)\" is not known")
    }
    return object
  }

  /// Reads `value` as an array.
  static func array(_ value: Any?, at location: String) throws -> [Any] {
    guard let array = value as? [Any] else {
      throw invalid(location, "a JSON array is needed")
    }
    return array
  }

  /// Reads `value` as a string.
  static func string(_ value: Any?, at location: String) throws -> String {
    guard let string = value as? String else {
      throw invalid(location, "a string is needed")
    }
    return string
  }

  /// Reads one session entry.
  static func session(_ value: Any, at location: String) throws -> ScriptedStubScript.Session {
    let entry = try object(value, at: location, allowing: ["match", "passes"])
    let match = try object(
      entry["match"], at: "\(location).match", allowing: ["promptContains"])
    let passes = try array(entry["passes"], at: "\(location).passes")
    return ScriptedStubScript.Session(
      promptContains: try string(match["promptContains"], at: "\(location).match.promptContains"),
      passes: try passes.enumerated().map { index, pass in
        let place = "\(location).passes[\(index)]"
        return try array(pass, at: place).enumerated().map { stepIndex, step in
          try Self.step(step, at: "\(place)[\(stepIndex)]")
        }
      })
  }

  /// Reads one step. A step has exactly one key.
  static func step(_ value: Any, at location: String) throws -> ScriptedPassStep {
    let known: Set = [textKey, reasoningKey, toolCallKey, gateKey, elicitKey, permissionKey]
    guard let step = value as? [String: Any], step.count == 1, let key = step.keys.first else {
      throw invalid(location, "a step is an object with exactly one key")
    }
    guard known.contains(key) else {
      throw invalid(
        location, "the step \"\(key)\" is not known; use \(known.sorted().joined(separator: ", "))")
    }
    let place = "\(location).\(key)"
    switch key {
    case textKey:
      return .textDelta(try string(step[key], at: place))
    case reasoningKey:
      return .reasoning(try string(step[key], at: place))
    case gateKey:
      return .gate(path: try string(step[key], at: place))
    case elicitKey:
      return .elicit(message: try string(step[key], at: place))
    case permissionKey:
      return .permission(title: try string(step[key], at: place))
    default:
      return try toolCall(step[key], at: place)
    }
  }

  /// Reads the value of a tool call step: the tool name, and the
  /// arguments, which become the JSON text that the tool call plays.
  static func toolCall(_ value: Any?, at location: String) throws -> ScriptedPassStep {
    let call = try object(value, at: location, allowing: ["name", "arguments"])
    let name = try string(call["name"], at: "\(location).name")
    let arguments = try object(
      call["arguments"], at: "\(location).arguments", allowing: nil)
    let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    return .toolCall(name: name, argumentsJSON: String(decoding: data, as: UTF8.self))
  }
}
