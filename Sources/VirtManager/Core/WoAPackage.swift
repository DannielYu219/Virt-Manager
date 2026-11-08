import Foundation

public extension VMRecord {
    /// Returns WoA paths anchored to this package, so a moved package remains usable.
    func resolvedWoAConfiguration(in packageDirectory: URL) -> WoAConfiguration? {
        guard var configuration = woaConfiguration else { return nil }
        configuration.diskImage = packageDirectory.appendingPathComponent("Disk.img")
        configuration.firmwareCode = packageDirectory.appendingPathComponent("FirmwareCode.fd")
        // Sharing is disabled for Windows. Preserve nested and top-level legacy fields independently.

        configuration.firmwareVariables = packageDirectory.appendingPathComponent("FirmwareVariables.fd")
        // App-bundled media must follow the current app after relocation or replacement.
        if configuration.driverISO == nil || configuration.driverISO?.lastPathComponent == "utm-guest-tools-0.1.275.iso" {
            configuration.driverISO = WoARuntimeBundle.locate()?.guestToolsISO
        }
        return configuration
    }
}

enum WoAPackage {
    static func prepare(record: VMRecord, in directory: URL, fileManager: FileManager = .default) throws -> VMRecord {
        guard record.kind == .windowsARM64, var configuration = record.woaConfiguration else { return record }

        let disk = directory.appendingPathComponent("Disk.img")
        let codeDestination = directory.appendingPathComponent("FirmwareCode.fd")
        let variablesDestination = directory.appendingPathComponent("FirmwareVariables.fd")
        let runtime = WoARuntimeBundle.locate()
        let codeSource = configuration.firmwareCode ?? (configuration.tpmEnabled ? runtime?.secureFirmwareCode : runtime?.firmwareCode)
        let existingVariables = fileManager.fileExists(atPath: variablesDestination.path) ? variablesDestination : nil
        let variablesSource = existingVariables ?? configuration.firmwareVariables ?? (configuration.tpmEnabled ? runtime?.secureFirmwareVariables : runtime?.firmwareVariables)

        try copyRegularFile(from: codeSource, to: codeDestination, fileManager: fileManager)
        try padFlash(codeDestination)
        if existingVariables == nil {
            try copyRegularFile(from: variablesSource, to: variablesDestination, fileManager: fileManager)
        }
        try padFlash(variablesDestination)

        // Keep a Guest Tools image that was chosen before packaging; everything else is package-relative.
        configuration.diskImage = disk
        configuration.firmwareCode = codeDestination
        configuration.firmwareVariables = variablesDestination
        var prepared = record
        prepared.woaConfiguration = configuration
        return prepared
    }

    private static func discoverFirmware(secure: Bool, fileManager: FileManager) -> (code: URL?, variables: URL?) {
        guard let runtime = WoARuntimeBundle.locate(fileManager: fileManager) else { return (nil, nil) }
        let code = secure ? runtime.secureFirmwareCode : runtime.firmwareCode
        let variables = secure ? runtime.secureFirmwareVariables : runtime.firmwareVariables
        guard fileManager.isReadableFile(atPath: code.path), fileManager.isReadableFile(atPath: variables.path) else { return (nil, nil) }
        return (code, variables)
    }

    /// The ARM "virt" machine's two pflash banks must each be exactly 64 MiB.
    static let pflashSize: UInt64 = 64 * 1024 * 1024

    private static func padFlash(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size < pflashSize else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: pflashSize)
    }

    private static func copyRegularFile(from source: URL?, to destination: URL, fileManager: FileManager) throws {
        guard let source else {
            throw VMStore.StoreError.operation("App 包中找不到 Windows ARM64 UEFI 固件。请重新构建安装。")
        }
        let normalizedSource = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard normalizedSource.isFileURL, fileManager.fileExists(atPath: normalizedSource.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw VMStore.StoreError.operation("Windows ARM64 firmware file is missing or not a regular file: \(normalizedSource.path)")
        }
        if normalizedSource.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: normalizedSource, to: destination)
    }
}
