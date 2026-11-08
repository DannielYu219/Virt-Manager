import Foundation
import Virtualization

@MainActor
public enum LinuxRosettaSupport {
    public enum Status {
        case available
        case notInstalled
        case notSupported
    }

    public static var status: Status {
        #if arch(arm64)
        if #available(macOS 13.0, *) {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed: return .available
            case .notInstalled: return .notInstalled
            case .notSupported: return .notSupported
            @unknown default: return .notSupported
            }
        }
        #endif
        return .notSupported
    }

    public static var isSupported: Bool {
        if case .notSupported = status { return false }
        return true
    }

    public static var isInstalled: Bool {
        if case .available = status { return true }
        return false
    }

    public static var statusText: String {
        switch status {
        case .available: return "Rosetta 已安装，可供 Linux 虚拟机使用。"
        case .notInstalled: return "尚未安装 Rosetta。请先在系统设置中安装 Rosetta，再启用 Linux Rosetta 支持。"
        case .notSupported: return "此设备或 macOS 版本不支持 Linux Rosetta。"
        }
    }

    public static func install() async throws {
        #if arch(arm64)
        guard #available(macOS 13.0, *) else {
            throw InstallationError.unsupported
        }
        guard case .notSupported = status else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                VZLinuxRosettaDirectoryShare.installRosetta { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                }
            }
            return
        }
        throw InstallationError.unsupported
        #else
        throw InstallationError.unsupported
        #endif
    }

    public enum InstallationError: LocalizedError {
        case unsupported
        public var errorDescription: String? { "此设备或 macOS 版本不支持安装 Linux Rosetta。" }
    }
}
