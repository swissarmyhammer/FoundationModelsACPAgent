import Foundation
import FoundationModelsACPAgentTestSupport

/// A folder label that only one test uses, and the removal of each folder that has it.
///
/// A fixture makes its folders in the folder of the run (``TestRunFolder/current``) with the label of its test
/// (``makeResolvedDirectory(label:)``): the working directory, and the user, cache and recording
/// folders of the harness. The tests of a suite run at the same time. So a test that removes its
/// folders by the label of its suite can remove the folders of a test that still runs. A label
/// with a new UUID is the label of one test only.
struct TestFolderLabel {
  /// The folder that holds the folders of the fixtures.
  private static var temporaryFolder: URL { TestRunFolder.current }

  /// The label: the name of the suite, then a new UUID.
  let value: String

  /// Makes a label for one test.
  ///
  /// - Parameter suite: The name of the suite, so a leftover folder says where it came from.
  init(_ suite: String) {
    value = "\(suite)-\(UUID().uuidString)"
  }

  /// Removes each folder in the folder of the run whose name starts with this label. Call it after
  /// each fixture of the test closed.
  func removeFolders() {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: Self.temporaryFolder.path)) ?? []
    for name in names where name.hasPrefix(value + "-") {
      try? FileManager.default.removeItem(
        at: Self.temporaryFolder.appendingPathComponent(name, isDirectory: true))
    }
  }
}
