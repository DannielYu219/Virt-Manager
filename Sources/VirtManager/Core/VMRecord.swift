import Foundation

public enum VMGuestKind: String, Codable, CaseIterable, Identifiable {
    case linux
    case macOS
    case windowsARM64

    public var id: String { rawValue }
}

public struct VMRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: VMGuestKind
    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var displayWidth: Int
    public var displayHeight: Int
    public var networkEnabled: Bool
    public var audioEnabled: Bool
    public var sharedDirectoryPath: String?
    public var sharedDirectoryReadOnly: Bool
    public var installerPath: String?
    public var macInstalled: Bool
    public var createdAt: Date
    public var macAddress: String
    public var rosettaEnabled: Bool
    public var clipboardEnabled: Bool
    public var woaConfiguration: WoAConfiguration?

    public init(id: UUID = UUID(), name: String = "New Machine", kind: VMGuestKind = .linux, cpuCount: Int = 4,
                memoryGiB: Int = 4, diskGiB: Int = 64, displayWidth: Int = 1920,
                displayHeight: Int = 1200, networkEnabled: Bool = true, audioEnabled: Bool = true,
                sharedDirectoryPath: String? = nil, sharedDirectoryReadOnly: Bool = true,
                installerPath: String? = nil, macInstalled: Bool = false,
                createdAt: Date = Date(), macAddress: String? = nil, rosettaEnabled: Bool = false, clipboardEnabled: Bool = false,
                woaConfiguration: WoAConfiguration? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.networkEnabled = networkEnabled
        self.audioEnabled = audioEnabled
        self.sharedDirectoryPath = sharedDirectoryPath
        self.sharedDirectoryReadOnly = sharedDirectoryReadOnly
        self.installerPath = installerPath
        self.macInstalled = macInstalled
        self.createdAt = createdAt
        self.macAddress = macAddress ?? Self.makeMACAddress()
        self.rosettaEnabled = rosettaEnabled
        self.clipboardEnabled = clipboardEnabled
        self.woaConfiguration = woaConfiguration
        // Keep both legacy sharing representations unchanged; Windows no longer exposes them.

    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, cpuCount, memoryGiB, diskGiB, displayWidth, displayHeight
        case networkEnabled, audioEnabled, sharedDirectoryPath, sharedDirectoryReadOnly
        case installerPath, macInstalled, createdAt, macAddress, rosettaEnabled, clipboardEnabled, woaConfiguration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(VMGuestKind.self, forKey: .kind)
        cpuCount = try values.decode(Int.self, forKey: .cpuCount)
        memoryGiB = try values.decode(Int.self, forKey: .memoryGiB)
        diskGiB = try values.decode(Int.self, forKey: .diskGiB)
        displayWidth = try values.decode(Int.self, forKey: .displayWidth)
        displayHeight = try values.decode(Int.self, forKey: .displayHeight)
        networkEnabled = try values.decode(Bool.self, forKey: .networkEnabled)
        audioEnabled = try values.decode(Bool.self, forKey: .audioEnabled)
        sharedDirectoryPath = try values.decodeIfPresent(String.self, forKey: .sharedDirectoryPath)
        sharedDirectoryReadOnly = try values.decode(Bool.self, forKey: .sharedDirectoryReadOnly)
        installerPath = try values.decodeIfPresent(String.self, forKey: .installerPath)
        macInstalled = try values.decode(Bool.self, forKey: .macInstalled)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        macAddress = try values.decode(String.self, forKey: .macAddress)
        rosettaEnabled = try values.decodeIfPresent(Bool.self, forKey: .rosettaEnabled) ?? false
        clipboardEnabled = try values.decodeIfPresent(Bool.self, forKey: .clipboardEnabled) ?? false
        woaConfiguration = try values.decodeIfPresent(WoAConfiguration.self, forKey: .woaConfiguration)
        // Do not merge inactive Windows sharing fields: decoding must remain lossless.

    }

    private static func makeMACAddress() -> String {
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        return ([0x02] + bytes.dropFirst()).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
