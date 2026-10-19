import FoundationModelsACPAgent
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouterTestSupport

/// A loader whose containers play `script` with the tool layers of the live
/// model loader on the tools of each session and of each fork.
///
/// Router puts the tool layers (the no-op check, the repetition check and
/// the tool hook layer) on the tools of a session in the live backend of
/// `LiveModelLoader` only. The scripted backend calls its tools directly,
/// thus with no layer a scripted tool call sends no `PreToolUse`,
/// `PreToolResult` and `PostToolUse`, and the no-op check does not run.
/// Each container of this loader is the scripted container of
/// ``makeScriptedModelLoader(script:recorder:lifetimes:)`` in the public
/// `HookLayeredLLMContainer` of Router, which puts the layers on the tools
/// through the same code path as the live backend.
///
/// Do not give this loader tools that already have the layers: each tool
/// call then sends each event two times.
///
/// - Parameter script: The steps every session plays.
/// - Returns: The loader to inject.
func makeHookLayeredModelLoader(script: [ScriptedPassStep]) -> StubModelLoader {
    var loader = makeScriptedModelLoader(script: script)
    let makeScriptedContainer = loader.makeLLMContainer
    loader.makeLLMContainer = { slot in HookLayeredLLMContainer(wrapping: makeScriptedContainer(slot)) }
    return loader
}
