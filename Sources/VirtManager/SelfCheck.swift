import Foundation
import AppKit
import Virtualization

/// Runs without creating NSApplication windows or starting a guest.
@MainActor enum SelfCheck {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VirtManager-check-\(UUID().uuidString)", isDirectory: true)
        let store = VMStore(rootURL: root)
        try checkWoAPackage(in: root.appendingPathComponent("WoA-fixture", isDirectory: true))
        try checkPackageMigration(in: root.appendingPathComponent("Migration-fixture", isDirectory: true))
        var record = VMRecord(name: "Self-check Linux", cpuCount: 2, memoryGiB: 2, diskGiB: 1)
        try store.create(record)
        guard store.machines.count == 1 else { throw AppFailure("Create/persistence check failed") }
        let directory = store.directory(for: record)
        let disk = directory.appendingPathComponent("Disk.img")
        let attrs = try FileManager.default.attributesOfItem(atPath: disk.path)
        guard (attrs[.size] as? NSNumber)?.uint64Value == 1024 * 1024 * 1024 else { throw AppFailure("Sparse disk size check failed") }
        do {
            let held = try VMExecutionLock(directory: directory)
            do {
                _ = try VMExecutionLock(directory: directory)
                throw AppFailure("Concurrent execution lock unexpectedly succeeded")
            } catch is VMExecutionLock.Failure { }
            withExtendedLifetime(held) {}
        }
        print("PASS: package runtime lock excludes concurrent use")
        let runtime = VMRuntime(record: record, directory: directory)
        try runtime.validate()
        let firmware = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("EFIVariableStore").path)
        guard ((firmware[.size] as? NSNumber)?.intValue ?? 0) > 0 else { throw AppFailure("EFI variable store is empty") }
        let identityBefore = try Data(contentsOf: directory.appendingPathComponent("MachineIdentifier"))
        try runtime.validate()
        guard try Data(contentsOf: directory.appendingPathComponent("MachineIdentifier")) == identityBefore else { throw AppFailure("Machine identity did not persist") }
        var invalid = record
        invalid.memoryGiB = -1
        do {
            try store.update(invalid)
            throw AppFailure("Invalid memory unexpectedly accepted")
        } catch is VMStore.StoreError { }
        record.name = "Updated self-check"
        try store.update(record)
        store.reload()
        guard store.machines.first?.name == record.name else { throw AppFailure("Update check failed") }
        do {
            try store.create(record)
            throw AppFailure("Duplicate creation unexpectedly succeeded")
        } catch is VMStore.StoreError { }
        let encoded = try JSONEncoder().encode(record)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "rosettaEnabled")
        let migrated = try JSONDecoder().decode(VMRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        guard !migrated.rosettaEnabled else { throw AppFailure("Legacy Rosetta default migration failed") }
        record.rosettaEnabled = true
        let decoded = try JSONDecoder().decode(VMRecord.self, from: JSONEncoder().encode(record))
        guard decoded.rosettaEnabled else { throw AppFailure("Rosetta setting roundtrip failed") }
        #if arch(arm64)
        if LinuxRosettaSupport.isInstalled {
            try VMRuntime(record: record, directory: directory).validate()
            print("PASS: Linux Rosetta configuration with host support installed")
        } else {
            do {
                try VMRuntime(record: record, directory: directory).validate()
                throw AppFailure("Missing Rosetta support unexpectedly accepted")
            } catch is VMRuntime.RuntimeError { }
            print("PASS: unavailable Rosetta rejected without installing components")
        }
        #endif
        record.clipboardEnabled = true
        try VMRuntime(record: record, directory: directory).validate()
        let clipboardRoundtrip = try PropertyListDecoder().decode(VMRecord.self, from: PropertyListEncoder().encode(record))
        guard clipboardRoundtrip.clipboardEnabled else { throw AppFailure("Clipboard setting roundtrip failed") }
        legacy.removeValue(forKey: "clipboardEnabled")
        let clipboardLegacy = try JSONDecoder().decode(VMRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        guard !clipboardLegacy.clipboardEnabled else { throw AppFailure("Legacy clipboard default migration failed") }
        print("PASS: clipboard console configuration and legacy setting compatibility")
        let options = DisplayResolutions.options(screen: NSScreen.main)
        for option in options where option.id.hasPrefix("host-") {
            guard option.width > 0, option.height > 0 else { throw AppFailure("Invalid host resolution") }
            if option.id == "host-16-10" {
                guard option.height == option.width * 10 / 16 else { throw AppFailure("16:10 resolution mismatch") }
            }
            print("Display preset: \(option.title)")
        }
        print("PASS: legacy migration, Rosetta persistence, host resolution presets")
        print("PASS: record persistence, sparse disk, EFI configuration validation, update, duplicate protection")
        print("Virtualization supported: \(VZVirtualMachine.isSupported)")
        print("Temporary check data: \(root.path)")
    }

    private static func checkWoAPackage(in root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let codeSource = root.appendingPathComponent("selected-code.fd")
        let variablesSource = root.appendingPathComponent("selected-vars.fd")
        try Data("firmware-code".utf8).write(to: codeSource)
        try Data("firmware-vars".utf8).write(to: variablesSource)

        let recordID = UUID()
        let options = WoAConfiguration(name: "WoA self-check", cpuCount: 3, memoryGiB: 6,
                                       firmwareCode: codeSource, firmwareVariables: variablesSource,
                                       graphicsMode: .software)
        let record = VMRecord(id: recordID, name: options.name, kind: .windowsARM64,
                              cpuCount: options.cpuCount, memoryGiB: options.memoryGiB, diskGiB: 1,
                              displayWidth: options.displayWidth, displayHeight: options.displayHeight,
                              networkEnabled: options.networkEnabled, woaConfiguration: options)
        let storeRoot = root.appendingPathComponent("Store", isDirectory: true)
        let store = VMStore(rootURL: storeRoot)
        try store.create(record)
        let package = store.directory(for: record)
        let disk = package.appendingPathComponent("Disk.img")
        guard fm.fileExists(atPath: disk.path),
              try Data(contentsOf: package.appendingPathComponent("FirmwareCode.fd")).prefix(13) == Data("firmware-code".utf8),
              try Data(contentsOf: package.appendingPathComponent("FirmwareVariables.fd")).prefix(13) == Data("firmware-vars".utf8),
              try fm.attributesOfItem(atPath: package.appendingPathComponent("FirmwareCode.fd").path)[.size] as? UInt64 == WoAPackage.pflashSize,
              try fm.attributesOfItem(atPath: package.appendingPathComponent("FirmwareVariables.fd").path)[.size] as? UInt64 == WoAPackage.pflashSize else {
            throw AppFailure("WoA package resources were not prepared")
        }
        guard let stored = try? VMPackage.read(from: package),
              stored.woaConfiguration?.diskImage?.standardizedFileURL == disk.standardizedFileURL else {
            throw AppFailure("WoA canonical disk path was not persisted")
        }

        let moved = root.appendingPathComponent("Moved.virtvm", isDirectory: true)
        let movedStoreRoot = root.appendingPathComponent("MovedStore", isDirectory: true)
        try fm.createDirectory(at: movedStoreRoot, withIntermediateDirectories: true)
        try fm.moveItem(at: package, to: moved)
        let movedStore = VMStore(rootURL: movedStoreRoot)
        let movedRecord = try movedStore.importPackage(at: moved)
        guard let resolved = movedRecord.resolvedWoAConfiguration(in: moved),
              resolved.diskImage?.standardizedFileURL == moved.appendingPathComponent("Disk.img").standardizedFileURL,
              resolved.firmwareCode?.standardizedFileURL == moved.appendingPathComponent("FirmwareCode.fd").standardizedFileURL,
              resolved.firmwareVariables?.standardizedFileURL == moved.appendingPathComponent("FirmwareVariables.fd").standardizedFileURL else {
            throw AppFailure("WoA package paths did not rebase after moving")
        }
        let variablesBefore = try Data(contentsOf: moved.appendingPathComponent("FirmwareVariables.fd"))
        var updated = movedRecord
        updated.woaConfiguration = resolved
        try movedStore.update(updated)
        guard try Data(contentsOf: moved.appendingPathComponent("FirmwareVariables.fd")) == variablesBefore else {
            throw AppFailure("WoA firmware variables were overwritten during update")
        }

        var legacyOptions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as! [String: Any]
        legacyOptions.removeValue(forKey: "graphicsMode")
        let legacyDecoded = try JSONDecoder().decode(WoAConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyOptions))
        guard legacyDecoded.graphicsMode == .software else { throw AppFailure("Legacy WoA graphics default migration failed") }
        var tools = resolved
        tools.installerISO = codeSource
        tools.driverISO = variablesSource
        tools.graphicsMode = .utmVenus
        let runtime = WoABackend.runtimeDirectory(for: recordID)
        let bundle = WoARuntimeBundle.locate()
        if let bundle {
            let plan = try WoABackend.plan(configuration: tools, macAddress: "02:00:00:00:00:01", runtime: runtime, package: moved,
                                           uuid: recordID, bundle: bundle, launcher: URL(fileURLWithPath: "/test/launcher"))
            let q = plan.qemu
            func has(_ values: String...) -> Bool { values.allSatisfy(q.contains) }
            guard has("-accel", "-cpu", "host", "-nodefaults", "-rtc", "virtio-serial-pci,id=virtio-serial"), q.contains(where: { $0.hasPrefix("hvf") }),
                  q.contains(where: { $0.hasPrefix("virtio-ramfb-gl,") && $0.contains("venus=true") }),
                  q.contains(where: { $0.hasPrefix("unix=on,") && $0.hasSuffix("gl=es") }),
                  q.contains(where: { $0.hasPrefix("nvme,") }), q.filter({ $0.hasPrefix("usb-storage,") }).count == 2,
                  q.contains(where: { $0.hasPrefix("tpm-crb-device") }), plan.swtpm != nil,
                  plan.tpmState.standardizedFileURL.path == moved.appendingPathComponent("TPM").standardizedFileURL.path else {
                throw AppFailure("WoA command omitted expected HVF/GPU/TPM/storage options")
            }
            guard q.contains(where: { $0.contains("venus=true") && $0.contains("neptune=true") }),
                  plan.environment["NPT_BACKEND"] != nil,
                  plan.environment["D3DMETAL_FRAMEWORK_PATH"] != nil else {
                throw AppFailure("Windows Venus requires a working Neptune desktop backend")
            }
            var highRefresh = tools
            highRefresh.displayRefreshHz = 120
            let highRefreshPlan = try WoABackend.plan(configuration: highRefresh, macAddress: "02:00:00:00:00:01", runtime: runtime, package: moved,
                                                     uuid: recordID, bundle: bundle, launcher: URL(fileURLWithPath: "/test/launcher"))
            guard highRefreshPlan.qemu[1] == bundle.qemu120Image.path,
                  fm.isExecutableFile(atPath: bundle.qemu120Image.path) else {
                throw AppFailure("120 Hz configuration did not select its packaged EDID engine")
            }
            var software = resolved
            software.tpmEnabled = false
            let softwarePlan = try WoABackend.plan(configuration: software, macAddress: "02:00:00:00:00:01", runtime: runtime, package: moved,
                                                   uuid: recordID, bundle: bundle, launcher: URL(fileURLWithPath: "/test/launcher"))
            guard softwarePlan.qemu.contains(where: { $0.contains("file=\(bundle.guestToolsISO.path),") }),
                  (try fm.attributesOfItem(atPath: bundle.guestToolsISO.path)[.size] as? NSNumber)?.int64Value == 143_935_488 else {
                throw AppFailure("Bundled Guest Tools ISO is missing or not attached by default")
            }
            print("PASS: bundled Guest Tools 0.1.275 ISO present and attached without download")
            guard softwarePlan.swtpm == nil, softwarePlan.qemu.contains(where: { $0.hasPrefix("virtio-ramfb,max_outputs=1,edid=on,xres=\(software.displayWidth),yres=\(software.displayHeight)") }),
                  !softwarePlan.qemu.contains(where: { $0.hasPrefix("tpm-crb") || $0.hasPrefix("virtio-ramfb-gl") }) else {
                throw AppFailure("WoA 2D/no-TPM plan is wrong")
            }
        }
        try checkWoARecovery(configuration: resolved, package: moved, bundle: bundle)
        var legacyDriver = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tools)) as! [String: Any]
        legacyDriver["graphicsMode"] = "unknownFutureMode"
        let futureDecoded = try JSONDecoder().decode(WoAConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyDriver))
        guard futureDecoded.driverISO == tools.driverISO, futureDecoded.graphicsMode == .software else {
            throw AppFailure("WoA driver ISO or unknown graphics mode did not decode")
        }
        print("PASS: WoA resource preparation, canonical disk, move rebasing, variables preservation, legacy graphics default, UTM QEMU command planning (HVF/NVMe/TPM/SPICE/GPU)")
    }

    private static func checkWoARecovery(configuration: WoAConfiguration, package: URL, bundle: WoARuntimeBundle?) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw AppFailure("WoA recovery: \(message)") }
        }
        func rejects(_ options: WoAConfiguration) throws {
            do { try options.validate() } catch is WoAError { return }
            throw AppFailure("WoA recovery accepted invalid configuration")
        }
        var options = configuration
        options.sharedDirectory = package.appendingPathComponent("missing-legacy-share")
        options.sharedDirectoryReadOnly = false
        try options.validate()
        let original = VMRecord(name: "Legacy shares", kind: .windowsARM64,
                                sharedDirectoryPath: "/different/legacy/share", sharedDirectoryReadOnly: true, woaConfiguration: options)
        let decoded = try PropertyListDecoder().decode(VMRecord.self, from: PropertyListEncoder().encode(original))
        try require(decoded.sharedDirectoryPath == original.sharedDirectoryPath &&
                    decoded.woaConfiguration?.sharedDirectory == options.sharedDirectory &&
                    decoded.woaConfiguration?.sharedDirectoryReadOnly == false, "inactive legacy sharing values must survive independently")
        for argument in ["-fsdev local,id=share,path=/tmp", "-virtfs local,path=/tmp",
                         "-device virtio-9p-pci,fsdev=share", "-device vhost-user-fs-pci",
                         "-readconfig /tmp/config", "--fsdev=local,id=x"] {
            var invalid = options; invalid.extraArguments = argument; try rejects(invalid)
        }
        options.extraArguments = "-snapshot"
        try options.validate()
        for invalidRule in ["tcp::0-:22", "tcp::65536-:22", "tcp:300.0.0.1:2222-:22", "tcp::22-:0", "udp::22-:22"] {
            var invalid = options; invalid.networkMode = .userPortForward
            invalid.networkPortForwards = [invalidRule]; try rejects(invalid)
        }
        var duplicate = options; duplicate.networkMode = .userPortForward
        duplicate.networkPortForwards = ["tcp::2222-:22", "tcp:127.0.0.1:2222-:23"]
        try rejects(duplicate)
        options.networkPortForwards = ["unused legacy value"]
        options.networkMode = .user
        try options.validate()
        for mode in WoANetworkMode.allCases {
            var candidate = options
            candidate.networkMode = mode
            candidate.networkEnabled = mode != .disconnected
            candidate.networkPortForwards = ["tcp:127.0.0.1:2222-:22", "tcp::2223-:23"]
            candidate.networkSocketPath = URL(fileURLWithPath: "/tmp/virtmgr,network.sock")
            try candidate.validate()
            if let bundle {
                let plan = try WoABackend.plan(configuration: candidate, macAddress: "02:00:00:00:00:01",
                                              runtime: URL(fileURLWithPath: "/tmp/vm-self-check"), package: package,
                                              uuid: UUID(), bundle: bundle, launcher: URL(fileURLWithPath: "/test/launcher"))
                try require(!plan.qemu.contains(where: { $0 == "-fsdev" || $0.contains("virtio-9p") || $0.contains("vhost-user-fs") }), "Windows must not expose a legacy host share")
                try require(plan.qemu.contains("-netdev") == (mode != .disconnected), "network device presence")
                if mode == .userPortForward { try require(plan.qemu.contains(where: { $0.contains("hostfwd=tcp:127.0.0.1:2222-:22") }), "loopback forwarding") }
                if mode == .user { try require(!plan.qemu.contains(where: { $0.contains("hostfwd=") }), "NAT ignores inactive forwarding") }
                if mode == .socket { try require(plan.qemu.contains(where: { $0.contains("addr.path=/tmp/virtmgr,,network.sock") }), "socket path comma escaping") }
            }
        }
        var missingSocket = options; missingSocket.networkMode = .socket; missingSocket.networkSocketPath = nil
        try rejects(missingSocket)
        print("PASS: inactive Windows shares preserved, unsupported filesystem arguments rejected, four network modes and forwarding validation")
    }

    private static func checkPackageMigration(in root: URL) throws {
        let fm = FileManager.default
        let record = VMRecord(name: "Legacy fixture", diskGiB: 1)
        let legacy = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let originalJSON = try JSONEncoder().encode(record)
        try originalJSON.write(to: legacy.appendingPathComponent("config.json"))
        let sentinel = Data("unchanged disk contents".utf8)
        try sentinel.write(to: legacy.appendingPathComponent("Disk.img"))
        try Data("identity".utf8).write(to: legacy.appendingPathComponent("MachineIdentifier"))
        // Simulate interruption after plist was written but before the directory rename.
        try VMPackage.write(record: record, to: legacy)
        let migrated = VMStore(rootURL: root)
        guard migrated.machines.contains(where: { $0.id == record.id }) else { throw AppFailure("Legacy package migration failed: \(migrated.errorMessage ?? "missing record")") }
        let package = migrated.directory(for: record)
        guard package.pathExtension == "virtvm", !fm.fileExists(atPath: legacy.path) else { throw AppFailure("Migration package path incorrect") }
        guard try Data(contentsOf: package.appendingPathComponent("Disk.img")) == sentinel else { throw AppFailure("Migration changed disk") }
        guard try Data(contentsOf: package.appendingPathComponent("config.json")) == originalJSON else { throw AppFailure("Migration changed JSON backup") }
        let restored = try VMPackage.read(from: package)
        guard restored.id == record.id, restored.name == record.name, restored.macAddress == record.macAddress,
              abs(restored.createdAt.timeIntervalSince(record.createdAt)) < 1 else { throw AppFailure("Migration config changed") }
        migrated.reload()
        guard migrated.machines.filter({ $0.id == record.id }).count == 1 else { throw AppFailure("Migration not idempotent") }
        let external = root.appendingPathComponent("External storage", isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let custom = VMRecord(name: "External fixture", diskGiB: 1)
        try migrated.create(custom, parentDirectory: external)
        let customURL = migrated.directory(for: custom)
        guard customURL.deletingLastPathComponent().standardizedFileURL == external.standardizedFileURL else { throw AppFailure("Custom location ignored") }
        migrated.reload()
        guard migrated.machines.contains(where: { $0.id == custom.id }) else { throw AppFailure("External package registry lost") }
        let importedRoot = root.appendingPathComponent("Other library", isDirectory: true)
        let imported = VMStore(rootURL: importedRoot)
        let opened = try imported.importPackage(at: customURL)
        guard opened.id == custom.id, imported.directory(for: opened) == customURL else { throw AppFailure("Opening portable package failed") }
        let reloaded = VMStore(rootURL: importedRoot)
        guard reloaded.machines.contains(where: { $0.id == custom.id }) else { throw AppFailure("Registry did not persist") }
        let copyURL = external.appendingPathComponent("Duplicate.virtvm", isDirectory: true)
        try fm.createDirectory(at: copyURL, withIntermediateDirectories: true)
        try VMPackage.write(record: custom, to: copyURL)
        do {
            _ = try imported.importPackage(at: copyURL)
            throw AppFailure("Conflicting UUID was silently accepted")
        } catch is VMStore.StoreError { }
        let movedURL = external.appendingPathComponent("Relocated.virtvm", isDirectory: true)
        guard customURL.standardizedFileURL.deletingLastPathComponent() == external.standardizedFileURL,
              customURL.pathExtension == "virtvm", !fm.fileExists(atPath: movedURL.path) else { throw AppFailure("Unsafe relocation fixture") }
        try fm.moveItem(at: customURL, to: movedURL)
        _ = try imported.importPackage(at: movedURL)
        guard imported.directory(for: custom).standardizedFileURL == movedURL.standardizedFileURL else { throw AppFailure("Relocating package failed") }
        print("PASS: legacy package migration, preserved disk and JSON backup, idempotency, custom location, package open, registry persistence, UUID conflict protection, relocation")
    }
}
