import Foundation
import FoundationModels
import FoundationModelsACPAgent
import FoundationModelsRouter

// MARK: - The paced stub model (cli-plan.md §5.9, §9)
//
// `ACP_AGENT_STUB_MODEL=1` gives a spawned `acp-agent` a deterministic
// model, and that is enough for every claim about what a turn SAYS. It
// is not enough for a claim about a turn that is still RUNNING: the
// library's echo backend answers in one chunk and in microseconds, so a
// signal always lands after the turn is over.
//
// `ACP_AGENT_STUB_CHUNK_DELAY_MS` holds a turn open. The prompt comes
// back word by word, with the named pause between the words, so a test
// can send `SIGINT` into a live turn across a real process boundary.
// The knob touches nothing when it is unset, and it is read only on the
// stub path.

/// A stub session backend that answers the prompt word by word, with a
/// pause between the words.
///
/// The pause is the whole feature: it makes a turn last long enough for
/// a signal to land inside it. Nothing else about the answer changes —
/// the chunks joined equal the prompt, exactly as the library's
/// one-chunk echo does.
///
/// A class, not a struct, because `LanguageModelSessionBackend` requires
/// `AnyObject`.
final class PacedEchoSessionBackend: LanguageModelSessionBackend {
    /// The pause between two chunks.
    private let pause: Swift.Duration

    /// The input and output token counts a paced turn reports. The
    /// values only satisfy the reader; nothing here counts tokens.
    private static let reportedTokenCounts = (input: 1, output: 1)

    /// Creates a backend that echoes each prompt at `pause` a chunk.
    ///
    /// - Parameter pause: The pause between two chunks.
    init(pausing pause: Swift.Duration) {
        self.pause = pause
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        var answer = ""
        for chunk in Self.chunks(of: prompt) {
            try await Task.sleep(for: pause)
            answer += chunk
        }
        return answer
    }

    func respond(
        to prompt: String, following grammar: Grammar, maxTokens: Int?
    ) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    func streamResponse(
        to prompt: String, maxTokens: Int?
    ) -> AsyncThrowingStream<String, Error> {
        let chunks = Self.chunks(of: prompt)
        let pause = self.pause
        return AsyncThrowingStream { continuation in
            // The pacing task is unstructured, so the consumer's own
            // cancellation does not reach it. The stream's termination
            // does, and a cancelled consumer terminates the stream, so
            // this is what stops the pacing when the turn is cancelled.
            let pacing = Task {
                for chunk in chunks {
                    try await Task.sleep(for: pause)
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pacing.cancel() }
        }
    }

    func makeFork() -> any LanguageModelSessionBackend {
        PacedEchoSessionBackend(pausing: pause)
    }

    func transcriptEntries() -> [Transcript.Entry] {
        []
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
        Self.reportedTokenCounts
    }

    /// The chunks of `prompt`: one per word, each keeping its trailing
    /// space, so the chunks joined equal the prompt byte for byte.
    ///
    /// - Parameter prompt: The text to cut.
    /// - Returns: The chunks, in order. A prompt with no space is one
    ///   chunk.
    private static func chunks(of prompt: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in prompt {
            current.append(character)
            if character == " " {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

/// A resident model that hands every session a
/// ``PacedEchoSessionBackend``.
///
/// All four factories are written out, because the public default of
/// `makeSession(instructions:tools:)` drops `tools` and forwards to
/// `makeSession(instructions:)`.
struct PacedEchoLLMContainer: LoadedLLMContainer {
    /// The counter of a model with no tokenizer: one token per character.
    var tokenCounter: any TokenCounter { CharacterCountTokenCounter() }

    /// The pause each session's backend puts between two chunks.
    let pause: Swift.Duration

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        PacedEchoSessionBackend(pausing: pause)
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        PacedEchoSessionBackend(pausing: pause)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        PacedEchoSessionBackend(pausing: pause)
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        PacedEchoSessionBackend(pausing: pause)
    }
}
