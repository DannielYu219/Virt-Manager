import Foundation
import Darwin

/// Cooperating instances lock a fixed inode; atomic config replacement cannot invalidate it.
final class VMExecutionLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        let url = directory.appendingPathComponent(".runtime.lock")
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure(message: "无法打开虚拟机运行锁：\(String(cString: strerror(errno)))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Failure(message: "此虚拟机已被另一个实例使用，请先将其关机。")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
