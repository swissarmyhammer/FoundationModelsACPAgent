import Foundation

@testable import FoundationModelsACPAgent

/// Writes the profile file `profiles/<name>.yaml` in the folder of one layer.
///
/// The call makes the `profiles` folder when it is not there. A test that
/// puts a profile file in a layer, with no profile store, uses this.
///
/// - Parameters:
///   - name: The name of the profile, which is the file name with no
///     extension.
///   - contents: The text of the file.
///   - layerDirectory: The folder of the layer, for example the project
///     dotfolder.
/// - Returns: The URL of the file.
/// - Throws: The error of the folder or of the write.
@discardableResult
func writeProfileFile(named name: String, contents: String, in layerDirectory: URL) throws -> URL {
  let profiles = layerDirectory.appendingPathComponent(ProfileFile.folderName, isDirectory: true)
  try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
  let file = profiles.appendingPathComponent("\(name).\(ProfileFile.fileExtension)")
  try contents.write(to: file, atomically: true, encoding: .utf8)
  return file
}
