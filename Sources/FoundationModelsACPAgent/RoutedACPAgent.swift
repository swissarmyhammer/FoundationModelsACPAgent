/// FoundationModelsACPAgent — the composed agent over the Router runtime.
///
/// This package layers over `FoundationModelsRouter` (the family runtime:
/// self-folding, token-metered, event-streaming, recorded sessions) and adds
/// slash-command support and configuration; `RoutedACPAgent` implements the
/// ACP `Agent` protocol from `FoundationModelsACP` (the zero-dependency wire
/// sibling). See `plan.md` at the repository root for the full design:
/// `AgentConfiguration` loaded from the dotfolder stack, the well-known tool
/// roster (built-ins + MCP), and the slash-command registry with dispatch at
/// the prompt owner.
///
/// Placeholder namespace: the real `RoutedACPAgent` lands per the plan's
/// board (task `gsebt3m`).
public enum RoutedACPAgentPackage {}
