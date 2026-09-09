import Foundation

/// The permissions of a directory only its owner can read, write and
/// enter. A test that made a directory unreadable puts this back, so the
/// directory can be removed again.
public let ownerOnlyPermissions = NSNumber(value: 0o700)

/// Sets the permissions of one directory.
///
/// A test that proves what the code does with a path it cannot read or
/// write calls this to make that path, and calls it again to put the
/// permissions back.
///
/// - Parameters:
///   - permissions: The POSIX permissions to set.
///   - directory: The directory to set them on.
/// - Throws: The attribute-write error.
public func setPermissions(_ permissions: NSNumber, of directory: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: permissions], ofItemAtPath: directory.path)
}
