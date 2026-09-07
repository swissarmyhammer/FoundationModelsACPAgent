import Foundation
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter

@testable import FoundationModelsACPAgent
@testable import acp_agent

// MARK: - The shared CLI composition fixture (cli-plan.md §4, §5.10)
//
// `RunCommandTests` and `InterruptTests` both drive `RunTurn` against an
// `AgentComposition.Composed` whose model is scripted. The construction
// is the same for both — a stub agent under the CLI's own dotfolder
// name, with every root in a throwaway directory — so it stands here
// once, and the two suites cannot drift apart.

/// The composition of one CLI turn, over a model the test wrote.
enum CLICompositionFixture {
    /// Composes over a model that plays `script`, so a turn gives a text
    /// the test wrote (plan.md §20.1). Nothing downloads and nothing
    /// loads.
    ///
    /// - Parameters:
    ///   - script: The steps the model plays on every turn.
    ///   - label: The directory label, so a leftover directory says where
    ///     it came from.
    /// - Returns: The composition, over the stub model path.
    /// - Throws: Whatever the agent construction throws.
    static func scripted(
        script: [ScriptedTurnStep], label: String
    ) async throws -> AgentComposition.Composed {
        try await make(loader: makeScriptedModelLoader(script: script), label: label)
    }

    /// Composes over `loader` under the CLI's own dotfolder name, with
    /// every root in a throwaway directory.
    ///
    /// - Parameters:
    ///   - loader: The model loader the agent resolves against.
    ///   - label: The directory label, so a leftover directory says where
    ///     it came from.
    /// - Returns: The composition, over the stub model path.
    /// - Throws: Whatever the agent construction throws.
    static func make(
        loader: any ModelLoader, label: String
    ) async throws -> AgentComposition.Composed {
        let agent = try await makeStubAgent(
            name: AgentComposition.dotfolderName,
            cacheDirectory: makeResolvedDirectory(label: "\(label)-cache"),
            recordingsDirectory: makeResolvedDirectory(label: "\(label)-recordings"),
            userDirectory: makeResolvedDirectory(label: "\(label)-user"),
            loader: loader)
        return AgentComposition.Composed(
            agent: agent, modelSource: .stub, configuration: AgentConfiguration())
    }
}
