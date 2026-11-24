import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The live order of the thoughts of a pass (Testudo ^ras4xe9, brief
/// FoundationModelsRouter-reasoning-order-2026-11-24): a thought shows where it starts. A pass
/// R1, tool call, R2, text A gives the wire updates thought R1, tool call, thought R2, message A,
/// and the resume replays them in that order.
@Suite(.closesHarnesses) struct LiveThoughtOrderTests {
  /// The label of the folders of the suite.
  private static let label = "LiveThoughtOrderTests"

  /// The first thought of the pass.
  private static let firstThought = "First I note the label."

  /// The thought after the tool call.
  private static let secondThought = "The label is noted, so I answer."

  /// The answer text.
  private static let answer = "The label is noted."

  /// A tool that gives back its label.
  struct NoteTool: Tool {
    let name = "note"
    let description = "Note a label."

    @Generable struct LabelArguments {
      @Guide(description: "The label.") var label: String
    }

    func call(arguments: LabelArguments) async throws -> String {
      arguments.label
    }
  }

  /// The pass of the test: R1, a call of ``NoteTool``, R2, text A.
  private static let script: [ScriptedPassStep] = [
    .reasoning(firstThought),
    .toolCall(name: "note", argumentsJSON: #"{"label":"zebra"}"#),
    .reasoning(secondThought),
    .textDelta(answer),
    .endPass,
  ]

  /// One step of the order of the updates.
  enum Step: Equatable {
    /// A thought with its text so far.
    case thought(String)

    /// A tool call.
    case tool

    /// An agent message with its text so far.
    case message(String)
  }

  /// The steps of `updates`, with the chunks of one message joined: a chunk with the message id
  /// of the step before adds its text to that step. Each tool call is one step, at its first
  /// update.
  ///
  /// - Parameter updates: The updates, live or replayed.
  /// - Returns: The steps.
  static func steps(of updates: [SessionUpdate]) -> [Step] {
    var steps: [Step] = []
    var lastId: String?
    var calls: Set<String> = []
    func add(_ step: Step, id: String) {
      if id == lastId, let last = steps.last {
        switch (last, step) {
        case (.thought(let a), .thought(let b)): steps[steps.count - 1] = .thought(a + b)
        case (.message(let a), .message(let b)): steps[steps.count - 1] = .message(a + b)
        default: steps.append(step)
        }
      } else {
        steps.append(step)
      }
      lastId = id
    }
    for update in updates {
      for message in ReplayedMessage.replayed(in: [update]) where message.kind != .user {
        add(message.kind == .thought ? .thought(message.text) : .message(message.text), id: message.id)
      }
      switch update {
      case .agentThoughtChunk(let chunk):
        add(.thought(Self.text(of: chunk.content)), id: chunk.messageId.rawValue)
      case .agentMessageChunk(let chunk):
        add(.message(Self.text(of: chunk.content)), id: chunk.messageId.rawValue)
      case .toolCallUpdate(let call):
        if calls.insert(call.toolCallId.rawValue).inserted {
          steps.append(.tool)
        }
        lastId = nil
      default:
        break
      }
    }
    return steps
  }

  /// The text of a content block.
  ///
  /// - Parameter block: The block.
  /// - Returns: The text, or an empty text for a block of another kind.
  private static func text(of block: ContentBlock) -> String {
    guard case .text(let text) = block else { return "" }
    return text.text
  }

  /// The pass gives the live updates and the replay in the order of the model.
  @Test func eachThoughtGoesOutWhereItStartsLiveAndInTheReplay() async throws {
    let folders = TestFolderLabel(Self.label)
    defer { folders.removeFolders() }
    let cwd = makeResolvedDirectory(label: "\(folders.value)-repo")
    let first = try await ScriptedPromptFixture.make(
      script: Self.script, label: folders.value, workingDirectory: cwd, hostTools: [NoteTool()])

    let run = try await ScriptedPromptFixture.runPrompt(on: first, text: "Note the label.")

    let expected: [Step] = [
      .thought(Self.firstThought), .tool, .thought(Self.secondThought), .message(Self.answer),
    ]
    let live = run.updates.filter { $0.sessionId == first.sessionId }.map(\.update)
    #expect(Self.steps(of: live) == expected)
    let replayed = try await first.closeAndResume(
      makeSecond: { cwd in
        try await ScriptedPromptFixture.make(
          script: [.endPass], label: folders.value, workingDirectory: cwd, hostTools: [NoteTool()])
      },
      read: { second, countBefore in
        Array(await second.collector.updates.dropFirst(countBefore)).map(\.update)
      })
    #expect(Self.steps(of: replayed) == expected)
  }
}
