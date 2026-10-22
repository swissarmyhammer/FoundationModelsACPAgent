import Foundation
import FoundationModels
import FoundationModelsRouter
import Synchronization

// MARK: - The gated stub model (cli-plan.md §5.9, §9)
//
// The stub model of ``ComposedAgent/ModelSource/stub`` gives a deterministic
// model, and that is enough for every claim about what a prompt SAYS. It
// is not enough for a claim about a prompt that is still RUNNING: the
// library's echo backend answers in one chunk and in microseconds, so a
// signal always lands after the prompt is over.
//
// The chunk gate of ``ComposedAgent/compose(name:workingDirectory:rootSettingsFolder:environment:modelSource:stubChunkGate:transcriptLocation:secretStore:hooksDataDirectory:skillsMarketplaceCacheDirectory:modelCacheDirectory:userDeviceTokens:reporting:)``
// holds a prompt open. The prompt comes back word by word, and before each
// word the stub reads one byte from a named pipe that the test holds. Thus
// a test can send `SIGINT` into a live prompt across a real process
// boundary, and the signal always lands before the words end, with no
// clock. The `acp-agent` executable reads the path of the pipe from
// `ACP_AGENT_STUB_CHUNK_GATE`. The gate touches nothing when it is `nil`,
// and it is read only on the stub path.

/// The gate of a stub answer: a named pipe that a test writes one byte into
/// for each chunk that may go out.
///
/// The first wait opens the pipe for reading, which blocks until the test
/// opens it for writing. Each wait then reads one byte. At the end of the
/// pipe (the test closed its end), each later wait returns at once, so the
/// answer runs to its end. Each read blocks a thread in the kernel, so the
/// reads run on a serial queue of their own and not on the cooperative pool.
final class StubChunkGate: Sendable {
    /// The state of the read end.
    private struct State {
        /// The read end, or `nil` before the first wait.
        var descriptor: Int32?

        /// Whether the pipe reached its end, or could not be opened. Then
        /// each wait returns at once.
        var isEnded = false
    }

    /// The path of the named pipe.
    private let path: String

    /// The queue of the blocking open and reads, in order.
    private let queue = DispatchQueue(label: "StubChunkGate")

    /// The state, under one lock.
    private let state = Mutex(State())

    /// Makes a gate over the named pipe at `path`.
    ///
    /// - Parameter path: The path of the named pipe.
    init(path: String) {
        self.path = path
    }

    /// Waits until the test lets the next chunk go out: one byte came, or
    /// the pipe reached its end.
    func waitForNextChunk() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                readOneByte()
                continuation.resume()
            }
        }
    }

    /// Opens the pipe at the first call, and reads one byte. Runs on
    /// ``queue`` only.
    private func readOneByte() {
        let current = state.withLock { $0 }
        guard !current.isEnded else { return }
        let descriptor: Int32
        if let opened = current.descriptor {
            descriptor = opened
        } else {
            descriptor = open(path, O_RDONLY)
            guard descriptor >= 0 else {
                state.withLock { $0.isEnded = true }
                return
            }
            state.withLock { $0.descriptor = descriptor }
        }
        var byte: UInt8 = 0
        if read(descriptor, &byte, 1) <= 0 {
            close(descriptor)
            state.withLock { state in
                state.descriptor = nil
                state.isEnded = true
            }
        }
    }
}

/// A stub session backend that answers the prompt word by word, and waits
/// at its ``StubChunkGate`` before each word.
///
/// The gate is the whole feature: it holds a prompt open until a signal
/// landed inside it. Nothing else about the answer changes — the chunks
/// joined equal the prompt, exactly as the library's one-chunk echo does.
///
/// A class, not a struct, because `LanguageModelSessionBackend` requires
/// `AnyObject`.
final class GatedEchoSessionBackend: LanguageModelSessionBackend {
    /// The gate before each chunk.
    private let gate: StubChunkGate

    /// The input and output token counts a gated prompt reports. The
    /// values only satisfy the reader; nothing here counts tokens.
    private static let reportedTokenCounts = (input: 1, output: 1)

    /// Creates a backend that echoes each prompt one chunk at a time, after
    /// `gate` lets each chunk go.
    ///
    /// - Parameter gate: The gate before each chunk.
    init(gatedBy gate: StubChunkGate) {
        self.gate = gate
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        var answer = ""
        for chunk in Self.chunks(of: prompt) {
            await gate.waitForNextChunk()
            try Task.checkCancellation()
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
        let gate = self.gate
        return AsyncThrowingStream { continuation in
            // The gating task is unstructured, so the consumer's own
            // cancellation does not reach it. The stream's termination
            // does, and a cancelled consumer terminates the stream, so
            // this is what stops the chunks when the prompt is cancelled.
            let gating = Task {
                for chunk in chunks {
                    await gate.waitForNextChunk()
                    guard !Task.isCancelled else { return }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in gating.cancel() }
        }
    }

    func makeFork() -> any LanguageModelSessionBackend {
        GatedEchoSessionBackend(gatedBy: gate)
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

/// A resident model that hands every session a ``GatedEchoSessionBackend``
/// over one shared ``StubChunkGate``.
///
/// All four factories are written out, because the public default of
/// `makeSession(instructions:tools:)` drops `tools` and forwards to
/// `makeSession(instructions:)`.
struct GatedEchoLLMContainer: LoadedLLMContainer {
    /// The counter of a model with no tokenizer: one token per character.
    var tokenCounter: any TokenCounter { CharacterCountTokenCounter() }

    /// The gate that each session's backend waits at before each chunk.
    let gate: StubChunkGate

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        GatedEchoSessionBackend(gatedBy: gate)
    }

    func makeSession(
        instructions: String?, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        GatedEchoSessionBackend(gatedBy: gate)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        GatedEchoSessionBackend(gatedBy: gate)
    }

    func makeSession(
        transcript: Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        GatedEchoSessionBackend(gatedBy: gate)
    }
}
