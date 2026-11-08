import Foundation

public enum WoANetworkMode: String, Codable, CaseIterable, Identifiable {
    case user
    case userPortForward
    case socket
    case disconnected

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .user: return "NAT 共享"
        case .userPortForward: return "NAT + 端口转发"
        case .socket: return "Socket 点对点"
        case .disconnected: return "断开网络"
        }
    }
    public var detail: String {
        switch self {
        case .user: return "通过宿主机 NAT 访问外网，客户机不可被局域网直接访问。"
        case .userPortForward: return "NAT 上增加 TCP 端口映射；建议绑定 127.0.0.1，仅允许本机访问。"
        case .socket: return "连接已运行、兼容 QEMU stream 协议的外部 Unix socket 服务；不会自动创建桥接、NAT 或 DHCP。"
        case .disconnected: return "不创建虚拟网卡。"
        }
    }
}

/// Graphics path offered by UTM 5.x's QEMU fork.
public enum WoAGraphicsMode: String, Codable, CaseIterable, Identifiable {
    case software
    case utmVenus
    case utmDirectX

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .software: return "兼容模式（2D）"
        case .utmVenus: return "Venus Vulkan（3D 实验）"
        case .utmDirectX: return "DirectX（3D 实验）"
        }
    }
    public var detail: String {
        switch self {
        case .software: return "virtio-ramfb / viogpudo 驱动，无 3D 加速。UEFI 与安装阶段始终可用。"
        case .utmVenus: return "Venus Vulkan + Neptune 桌面显示。Windows viogpu3d 的桌面合成仍需要 Direct3D，已同时启用匹配的宿主后端。"
        case .utmDirectX: return "DirectX 转换后端配置错误时，部分 Windows 系统会黑屏。切换前请保存客户机数据。"
        }
    }
    public var usesGL: Bool { self != .software }
}

/// Persisted options for a Windows on ARM64 guest that runs in UTM's QEMU fork.
public struct WoAConfiguration: Codable, Equatable {
    public var name: String
    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskImage: URL?
    public var installerISO: URL?
    public var firmwareCode: URL?
    public var firmwareVariables: URL?
    public var displayWidth: Int
    public var displayHeight: Int
    /// Guest EDID refresh rate; actual frame rate depends on the guest and rendering path.
    public var displayRefreshHz: Int
    public var networkEnabled: Bool
    public var networkMode: WoANetworkMode
    /// QEMU TCP forwarding rules, e.g. tcp:127.0.0.1:2222-:22; legacy wildcard binds remain supported.
    public var networkPortForwards: [String]
    public var networkSocketPath: URL?
    /// Inactive legacy sharing data, retained without exposing a host folder to Windows.
    public var sharedDirectory: URL?
    public var sharedDirectoryReadOnly: Bool
    public var audioEnabled: Bool
    public var tpmEnabled: Bool
    public var graphicsMode: WoAGraphicsMode
    public var qemuExecutable: URL?
    /// UTM Guest Tools ISO (SPICE agent, VirtIO, display drivers), attached as a second CD.
    public var driverISO: URL?
    /// Optional extra QEMU arguments, split on whitespace. Unsupported filesystem devices are rejected.
    public var extraArguments: String
    /// USB devices explicitly assigned to this WoA guest. Host HID/root-hub devices are never auto-captured.
    public var usbAssignments: [WoAUSBSelection]
    /// When enabled, newly attached eligible USB devices matching the host policy are offered for attachment.
    public var autoConnectNewUSBDevices: Bool

    public init(name: String = "Windows ARM64", cpuCount: Int = 4, memoryGiB: Int = 8,
                diskImage: URL? = nil, installerISO: URL? = nil, firmwareCode: URL? = nil,
                firmwareVariables: URL? = nil, displayWidth: Int = 1920, displayHeight: Int = 1200,
                displayRefreshHz: Int = 60,
                networkEnabled: Bool = true, networkMode: WoANetworkMode = .user, networkPortForwards: [String] = [], networkSocketPath: URL? = nil,
                sharedDirectory: URL? = nil, sharedDirectoryReadOnly: Bool = true,
                audioEnabled: Bool = true, tpmEnabled: Bool = true,
                graphicsMode: WoAGraphicsMode = .software, qemuExecutable: URL? = nil,
                driverISO: URL? = nil, extraArguments: String = "", usbAssignments: [WoAUSBSelection] = [], autoConnectNewUSBDevices: Bool = false) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskImage = diskImage
        self.installerISO = installerISO
        self.firmwareCode = firmwareCode
        self.firmwareVariables = firmwareVariables
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayRefreshHz = displayRefreshHz
        self.networkMode = networkEnabled ? networkMode : .disconnected
        self.networkEnabled = self.networkMode != .disconnected
        self.networkPortForwards = networkPortForwards
        self.networkSocketPath = networkSocketPath
        self.sharedDirectory = sharedDirectory
        self.sharedDirectoryReadOnly = sharedDirectoryReadOnly
        self.audioEnabled = audioEnabled
        self.tpmEnabled = tpmEnabled
        self.graphicsMode = graphicsMode
        self.qemuExecutable = qemuExecutable
        self.driverISO = driverISO
        self.extraArguments = extraArguments
        self.usbAssignments = usbAssignments
        self.autoConnectNewUSBDevices = autoConnectNewUSBDevices
    }

    private enum CodingKeys: String, CodingKey {
        case name, cpuCount, memoryGiB, diskImage, installerISO, firmwareCode, firmwareVariables
        case displayWidth, displayHeight, displayRefreshHz, networkEnabled, networkMode, networkPortForwards, networkSocketPath
        case sharedDirectory, sharedDirectoryReadOnly, audioEnabled, tpmEnabled, graphicsMode
        case qemuExecutable, driverISO, extraArguments, usbAssignments, autoConnectNewUSBDevices
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Windows ARM64"
        cpuCount = try values.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 4
        memoryGiB = try values.decodeIfPresent(Int.self, forKey: .memoryGiB) ?? 8
        diskImage = try values.decodeIfPresent(URL.self, forKey: .diskImage)
        installerISO = try values.decodeIfPresent(URL.self, forKey: .installerISO)
        firmwareCode = try values.decodeIfPresent(URL.self, forKey: .firmwareCode)
        firmwareVariables = try values.decodeIfPresent(URL.self, forKey: .firmwareVariables)
        displayWidth = try values.decodeIfPresent(Int.self, forKey: .displayWidth) ?? 1920
        displayHeight = try values.decodeIfPresent(Int.self, forKey: .displayHeight) ?? 1200
        displayRefreshHz = try values.decodeIfPresent(Int.self, forKey: .displayRefreshHz) ?? 60
        networkEnabled = try values.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? true
        networkMode = try values.decodeIfPresent(WoANetworkMode.self, forKey: .networkMode) ?? (networkEnabled ? .user : .disconnected)
        // Explicit modes are authoritative; networkEnabled is the legacy compatibility flag.
        networkEnabled = networkMode != .disconnected
        networkPortForwards = try values.decodeIfPresent([String].self, forKey: .networkPortForwards) ?? []
        networkSocketPath = try values.decodeIfPresent(URL.self, forKey: .networkSocketPath)
        sharedDirectory = try values.decodeIfPresent(URL.self, forKey: .sharedDirectory)
        sharedDirectoryReadOnly = try values.decodeIfPresent(Bool.self, forKey: .sharedDirectoryReadOnly) ?? true
        audioEnabled = try values.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? true
        tpmEnabled = try values.decodeIfPresent(Bool.self, forKey: .tpmEnabled) ?? true
        // Legacy configurations stored "utmDirectX" before "utmVenus"; unknown values fall back to 2D.
        graphicsMode = (try? values.decodeIfPresent(WoAGraphicsMode.self, forKey: .graphicsMode)) ?? .software
        qemuExecutable = try values.decodeIfPresent(URL.self, forKey: .qemuExecutable)
        driverISO = try values.decodeIfPresent(URL.self, forKey: .driverISO)
        extraArguments = try values.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
        usbAssignments = try values.decodeIfPresent([WoAUSBSelection].self, forKey: .usbAssignments) ?? []
        autoConnectNewUSBDevices = try values.decodeIfPresent(Bool.self, forKey: .autoConnectNewUSBDevices) ?? false
    }

    /// Matches the whitespace-only parser used by the launch plan; this is not a shell.
    private func validateExtraArguments() throws {
        let arguments = extraArguments.split(whereSeparator: \.isWhitespace).map(String.init)
        for argument in arguments {
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            let name = option.drop(while: { $0 == "-" }).lowercased()
            // External config files could add filesystem devices without appearing in this list.
            if argument.hasPrefix("-"), ["fsdev", "virtfs", "virtfs_synth", "readconfig"].contains(name) {
                throw WoAError.invalid("Windows 文件夹共享未实现；额外 QEMU 参数不允许 -fsdev、-virtfs 或外部配置文件。旧共享设置仍会保留。")
            }
            let components = argument.lowercased().components(separatedBy: CharacterSet(charactersIn: ",=:\"'{}[]"))
            if components.contains(where: { $0.hasPrefix("virtio-9p") || $0.hasPrefix("virtio-fs") || $0.hasPrefix("vhost-user-fs") || $0 == "virtiofs" }) {
                throw WoAError.invalid("Windows 文件夹共享未实现，已阻止通过额外 QEMU 参数添加 9p/virtiofs 设备。")
            }
        }
    }

    public func validate(fileManager: FileManager = .default) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WoAError.invalid("Windows ARM64 名称不能为空。") }
        guard (1...64).contains(cpuCount) else { throw WoAError.invalid("Windows ARM64 CPU 数量必须在 1 到 64 之间。") }
        guard (2...1024).contains(memoryGiB) else { throw WoAError.invalid("Windows ARM64 内存必须在 2 到 1024 GiB 之间。") }
        guard (640...16384).contains(displayWidth), (480...16384).contains(displayHeight) else { throw WoAError.invalid("Windows ARM64 显示尺寸不在支持范围内。") }
        guard [60, 120].contains(displayRefreshHz) else { throw WoAError.invalid("Windows ARM64 显示刷新率必须为 60 或 120 Hz。") }
        if networkMode == .userPortForward {
            var hostPorts = Set<Int>()
            for rule in networkPortForwards {
                guard rule.range(of: #"^tcp:(?:[0-9]{1,3}(?:\.[0-9]{1,3}){3})?:[0-9]{1,5}-:[0-9]{1,5}$"#, options: .regularExpression) != nil else {
                    throw WoAError.invalid("端口转发格式应为 tcp:宿主 IPv4:宿主端口-:客户机端口，例如 tcp:127.0.0.1:2222-:22；也兼容 tcp::2222-:22。")
                }
                let parts = rule.split(separator: ":", omittingEmptySubsequences: false)
                let address = String(parts[1])
                guard address.isEmpty || address.split(separator: ".").allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) else {
                    throw WoAError.invalid("端口转发的宿主 IPv4 地址无效。")
                }
                guard let host = Int(parts[2].dropLast()), let guest = Int(parts[3]),
                      (1...65535).contains(host), (1...65535).contains(guest) else {
                    throw WoAError.invalid("转发端口必须在 1 到 65535 之间。")
                }
                // Duplicate bindings fail at launch. Conservatively reserve each TCP host port once.
                guard hostPorts.insert(host).inserted else { throw WoAError.invalid("同一 TCP 宿主端口不能重复转发。") }
            }
        }
        if networkMode == .socket {
            guard let path = networkSocketPath, path.isFileURL, path.path != "/",
                  path.path.utf8.count < 104,
                  !path.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw WoAError.invalid("Socket 网络模式需要有效的本地 Unix socket 路径（UTF-8 长度小于 104 字节）。")
            }
        }
        // These legacy paths are retained for lossless saves, not used or validated for launch.
        // Windows sharing remains unavailable until SPICE WebDAV is implemented end-to-end.
        try validateExtraArguments()
        let files: [(String, URL?)] = [("磁盘", diskImage), ("UEFI 固件", firmwareCode), ("UEFI 变量", firmwareVariables),
                                       ("安装 ISO", installerISO), ("Guest Tools ISO", driverISO)]
        for (label, url) in files {
            guard let url else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw WoAError.invalid("Windows ARM64 \(label)文件不存在或不是普通文件：\(url.path)")
            }
        }
    }
}

public enum WoAError: LocalizedError, Equatable {
    case invalid(String)
    case qemuUnavailable(String)
    case unsupportedHost(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .qemuUnavailable(let message), .unsupportedHost(let message): return message }
    }
}
