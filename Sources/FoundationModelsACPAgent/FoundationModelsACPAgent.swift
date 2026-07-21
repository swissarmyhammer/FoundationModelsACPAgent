/// FoundationModelsACPAgent — the composed agent over the harness.
///
/// This package layers over `FoundationModelsAgentHarness` and
/// `FoundationModelsRouter` and adds slash-command support and configuration;
/// it implements the ACP `Agent` protocol from `FoundationModelsACP` (the
/// zero-dependency wire sibling). See `plan.md` at the repository root for
/// the full design: `AgentConfiguration` loaded from the dotfolder stack,
/// the well-known tool roster (built-ins + MCP), the slash-command registry
/// with dispatch at the prompt owner, and `HarnessACPAgent`.
///
/// Placeholder file: implementation lands per the plan's build order.
public enum FoundationModelsACPAgent {}
