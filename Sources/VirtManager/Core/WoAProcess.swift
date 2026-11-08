import Darwin
import Foundation

/// Owns one helper process (QEMU or swtpm) and exposes a small lifecycle surface.
@MainActor
public final class WoAProcess: NSObject {
    public enum State: Equatable { case stopped, running, stopping }

    public private(set) var state: State = .stopped
    public private(set) var process: Process?
    public private(set) var command: [String] = []
    public var onExit: ((Int32) -> Void)?
    public var isRunning: Bool { state != .stopped }
    public var processIdentifier: Int32? { process?.processIdentifier }

    /// Starts `command` (executable first). stdout and stderr are appended to `log` when given.
    public func start(command: [String], log: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard state == .stopped else { throw Error.alreadyRunning }
        guard let executable = command.first, !executable.isEmpty else { throw Error.invalidCommand }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(command.dropFirst())
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        var openedLog: FileHandle?
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            openedLog = try? FileHandle(forWritingTo: log)
            _ = try? openedLog?.seekToEnd()
            child.standardOutput = openedLog
            child.standardError = openedLog
        }
        let logHandle = openedLog
        child.terminationHandler = { [weak self] finished in
            try? logHandle?.close()
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.state = .stopped
                self.onExit?(finished.terminationStatus)
            }
        }
        do { try child.run() } catch { throw Error.launchFailed(error.localizedDescription) }
        process = child
        self.command = command
        state = .running
    }

    public func requestStop() {
        guard let process, process.isRunning else { state = .stopped; return }
        process.terminate()
        state = .stopping
    }

    public func forceStop() {
        guard let process, process.isRunning else { state = .stopped; return }
        kill(process.processIdentifier, SIGKILL)
        state = .stopping
    }

    public enum Error: LocalizedError, Equatable {
        case alreadyRunning
        case invalidCommand
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Windows ARM64 辅助进程已经在运行。"
            case .invalidCommand: return "Windows ARM64 启动命令为空。"
            case .launchFailed(let message): return "无法启动 Windows ARM64 辅助进程：\(message)"
            }
        }
    }
}

/// Minimal QMP client over a UNIX socket. Commands are synchronous on a private queue.
final class QMPClient: @unchecked Sendable {
    enum QMPError: LocalizedError {
        case notConnected
        case failed(String)
        var errorDescription: String? {
            switch self { case .notConnected: return "QMP 未连接。"; case .failed(let message): return "QEMU 拒绝了命令：\(message)" }
        }
    }

    private let queue = DispatchQueue(label: "virtmgr.qmp")
    private var descriptor: Int32 = -1
    private var buffer = Data()

    func connect(path: String) async throws {
        try await run {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw QMPError.failed(String(cString: strerror(errno))) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw QMPError.failed("路径过长") }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { let message = String(cString: strerror(errno)); close(fd); throw QMPError.failed(message) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            self.descriptor = fd
            _ = try self.readMessage()      // greeting
            _ = try self.send(["execute": "qmp_capabilities"])
        }
    }

    @discardableResult
    func execute(_ command: String, arguments: [String: Any]? = nil) async throws -> [String: Any] {
        try await run {
            var message: [String: Any] = ["execute": command]
            if let arguments { message["arguments"] = arguments }
            return try self.send(message)
        }
    }

    func disconnect() {
        queue.async {
            if self.descriptor >= 0 { close(self.descriptor); self.descriptor = -1 }
        }
    }

    private func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func send(_ message: [String: Any]) throws -> [String: Any] {
        guard descriptor >= 0 else { throw QMPError.notConnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) }
        guard written == data.count else { throw QMPError.notConnected }
        while true {
            let reply = try readMessage()
            if reply["event"] != nil { continue }
            if let error = reply["error"] as? [String: Any] { throw QMPError.failed(error["desc"] as? String ?? "unknown") }
            return reply
        }
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { throw QMPError.notConnected }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
