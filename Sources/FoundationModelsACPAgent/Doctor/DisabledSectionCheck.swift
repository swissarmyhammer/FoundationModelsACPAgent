import Foundation
import FoundationModelsExtras

/// The finding of one tool section the configuration turned off
/// (cli-plan.md §5.12).
///
/// Two components report such a row: ``ToolsDoctor`` for the shell and the
/// MCP servers, and ``RuntimeDoctor`` for the skills. The row says the same
/// thing in each case — the section is off, so the tool is not mounted and
/// nothing behind it is checked — so the sentence is written one time here.
///
/// The row passes. A tool a person turned off on purpose is not a fault.
enum DisabledSectionCheck {
    /// The word the row reports, so a person sees why the tool is absent
    /// from the roster.
    static let disabledWord = "disabled"

    /// The finding of one section that is off.
    ///
    /// - Parameters:
    ///   - name: What the finding is called in the report.
    ///   - key: The dotted key path that turned the tool off.
    ///   - category: The group the finding belongs to.
    /// - Returns: A pass that says disabled.
    static func check(name: String, key: String, category: String) -> HealthCheck {
        .ok(
            name: name, message: "\(key) is \(disabledWord), so this tool is not mounted",
            category: category)
    }
}
