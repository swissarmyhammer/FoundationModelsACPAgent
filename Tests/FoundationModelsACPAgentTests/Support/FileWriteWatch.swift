import Dispatch
import Foundation
import FoundationModelsACPAgentTestSupport
import Synchronization

/// The wait for a fact about a file that another task writes.
///
/// The wait watches the file with a kernel event source (a vnode source for
/// `write` and `extend`). Each write to the file checks the fact again, so
/// the wait uses no clock and no poll.
enum FileWriteWatch {
    /// Waits until `fact` is true. Returns at once when it is true now.
    ///
    /// The source is armed first, and the fact is read after that, so a
    /// write that comes between the two reads is not lost.
    ///
    /// - Parameters:
    ///   - url: The file to watch. It must exist.
    ///   - condition: The name of the condition, for the error of a
    ///     cancelled wait.
    ///   - fact: Tells if the condition is true. It reads the file.
    /// - Throws: ``ConditionWaitCancelled`` when the task of the wait is
    ///   cancelled before the condition comes, or `CocoaError` when the file
    ///   cannot be opened.
    static func wait(
        on url: URL, for condition: String, until fact: @escaping @Sendable () -> Bool
    ) async throws {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let queue = DispatchQueue(label: "FileWriteWatch")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend], queue: queue)
        let result = OneShot()
        source.setEventHandler {
            if fact() {
                result.fire(true)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        defer { source.cancel() }
        let met = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                result.arm(continuation)
                source.resume()
                queue.async {
                    if fact() {
                        result.fire(true)
                    } else if Task.isCancelled {
                        result.fire(false)
                    }
                }
            }
        } onCancel: {
            result.fire(false)
        }
        guard met else {
            throw ConditionWaitCancelled(condition: condition)
        }
    }
}

