/// The mount orders of the session tools that the tool catalog gives the
/// model. `ToolCatalogTests` and `AgentsToolTests` assert the same orders, so
/// each list lives here one time, in the pattern of ``FilesVerbSupport``.
enum MountOrder {
    /// The mount order of a default context: the two Multitool session
    /// tools, then the standalone `skills` tool, then the standalone
    /// `agents` tool.
    static let defaultToolNames = ["searchTools", "runCode", "skills", "agents"]
}
