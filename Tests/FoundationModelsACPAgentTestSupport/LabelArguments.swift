import FoundationModels

/// The arguments of a test tool that takes one label.
///
/// The scripted stub suites use it for the tools of a pass. Some tools give the label back, and
/// some tools do not read it.
@Generable
public struct LabelArguments: Sendable {
  /// The label of the call.
  public var label: String

  /// Makes the arguments.
  ///
  /// - Parameter label: The label of the call.
  public init(label: String) {
    self.label = label
  }
}
