import AppKit
import Foundation

/// Developer-only end-to-end check: `VirtManager --woa-probe <installer.iso> <output-dir> [software|venus|directx] [notpm]`.
/// Boots the ISO in a disposable WoA package, saves two screenshots taken through the SPICE display and stops it.
@MainActor enum WoAProbe {
    static func run(arguments: [String]) async -> Int32 {
        guard arguments.count >= 2 else { fputs("usage: --woa-probe <iso> <output-dir> [mode] [notpm]\n", stderr); return 64 }
        let iso = URL(fileURLWithPath: arguments[0])
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let mode: WoAGraphicsMode = arguments.count > 2 ? (["venus": .utmVenus, "directx": .utmDirectX][arguments[2]] ?? .software) : .software
        let tpm = !arguments.contains("notpm")
        let caps = WoABackend.capabilities()
        print("Bundled UTM-compatible runtime \(WoARuntimeBundle.locate()?.version ?? "missing"): GL=\(caps.hasGLDevice) venus=\(caps.hasVenus) blob=\(caps.hasBlob) neptune=\(caps.hasNeptune)")
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("virtmgr-probe-\(UUID().uuidString.prefix(6))", isDirectory: true)
            let store = VMStore(rootURL: root)
            if arguments.contains("installed") { return try await checkInstalled(package: iso, output: output, mode: mode) }
            let configuration = WoAConfiguration(name: "WoA probe", cpuCount: 4, memoryGiB: 4, installerISO: iso, tpmEnabled: tpm, graphicsMode: mode)
            let record = VMRecord(name: "WoA probe", kind: .windowsARM64, cpuCount: 4, memoryGiB: 4, diskGiB: 8, woaConfiguration: configuration)
            try store.create(record)
            if arguments.contains("multi") { return try await checkConcurrent(store: store, first: record, configuration: configuration, output: output) }
            let runtime = VMRuntime(record: store.machines[0], directory: store.directory(for: record))
            runtime.start()
            var waited = 0.0
            while runtime.woa?.displayView?.hasFrame != true {
                try await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
                if let message = runtime.errorMessage { throw AppFailure(message) }
                if waited > 90 { throw AppFailure("no SPICE frame within 90 s (status \(runtime.status))") }
            }
            print("first frame after \(waited)s, agent=\(runtime.woa?.displayView?.client.agentConnected ?? false)")
            if arguments.contains("window"), let view = runtime.woa?.displayView {
                let controller = VMDisplayController(view: view, title: "WoA probe", onClose: {})
                controller.show()
                try await Task.sleep(nanoseconds: 4_000_000_000)
                if let content = view.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("window.png"))
                    print("window rendered \(rep.pixelsWide)x\(rep.pixelsHigh), view frame \(view.frame), hasFrame \(view.hasFrame)")
                } else { print("no window content view") }
            }
            try await Task.sleep(nanoseconds: 12_000_000_000)
            try save(runtime, to: output.appendingPathComponent("frame1.png"))
            if arguments.contains("edid") {
                try await runtime.woa?.dumpEDIDForProbe(to: output.appendingPathComponent("edid.bin"))
                runtime.forceStop()
                for _ in 0..<100 { if runtime.isStopped { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                return runtime.isStopped ? 0 : 1
            }
            runtime.woa?.displayView?.client.key(0x1C, down: true)    // Return
            runtime.woa?.displayView?.client.key(0x1C, down: false)
            try await Task.sleep(nanoseconds: 25_000_000_000)
            try save(runtime, to: output.appendingPathComponent("frame2.png"))
            try await Task.sleep(nanoseconds: 40_000_000_000)
            try save(runtime, to: output.appendingPathComponent("frame3.png"))
            runtime.forceStop()
            for _ in 0..<80 where !runtime.isStopped { try await Task.sleep(nanoseconds: 250_000_000) }
            print("stopped=\(runtime.isStopped) status=\(runtime.status)")
            print("package: \(store.directory(for: record).path)")
            return runtime.isStopped ? 0 : 1
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    /// Diagnostic boots use QEMU's temporary overlay and copies of firmware/TPM state.
    private static func checkInstalled(package: URL, output: URL, mode: WoAGraphicsMode) async throws -> Int32 {
        let original = try VMPackage.read(from: package)
        let executionLock = try VMExecutionLock(directory: package)
        defer { withExtendedLifetime(executionLock) {} }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("windows-display-check-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        guard original.kind == .windowsARM64 else { throw AppFailure("Installed probe requires a Windows ARM64 package") }
        for name in ["FirmwareCode.fd", "FirmwareVariables.fd", "TPM"] {
            let source = package.appendingPathComponent(name)
            if name == "TPM" && !FileManager.default.fileExists(atPath: source.path) { continue }
            try FileManager.default.copyItem(at: source, to: temporary.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("Disk.img"), withDestinationURL: package.appendingPathComponent("Disk.img"))
        var record = original
        // Keep hardware UUID/NVMe identity stable to avoid artificial boot/BitLocker changes.
        // The original execution lock excludes concurrent use; all writes use -snapshot.
        record.installerPath = nil
        record.networkEnabled = false
        record.audioEnabled = false
        record.clipboardEnabled = false
        guard var options = original.resolvedWoAConfiguration(in: temporary) else { throw AppFailure("Windows configuration missing") }
        options.installerISO = nil
        options.driverISO = nil
        options.networkEnabled = false
        options.networkMode = .disconnected
        options.audioEnabled = false
        options.usbAssignments = []
        options.autoConnectNewUSBDevices = false
        options.graphicsMode = mode
        options.extraArguments = "-snapshot"
        record.woaConfiguration = options
        try VMPackage.write(record: record, to: temporary)
        let runtime = VMRuntime(record: record, directory: temporary)
        defer { runtime.forceStop() }
        let bootStart = Date()
        runtime.start()
        var lastImageSignature: Int?
        for index in 0..<120 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let error = runtime.errorMessage { throw AppFailure(error) }
            if index == 75 {
                runtime.woa?.displayView?.client.key(0x1C, down: true)
                runtime.woa?.displayView?.client.key(0x1C, down: false)
            }
            if let image = runtime.woa?.displayView?.client.currentImage(),
               let data = image.dataProvider?.data {
                let signature = CFDataGetLength(data) ^ image.width ^ image.height
                if lastImageSignature != signature {
                    print("DISPLAY timing t=\(String(format: "%.3f", Date().timeIntervalSince(bootStart))) size=\(image.width)x\(image.height) agent=\(runtime.woa?.displayView?.client.agentConnected ?? false)")
                    lastImageSignature = signature
                }
            }
            if [10, 30, 60, 90, 119].contains(index) {
                if runtime.woa?.displayView?.client.currentImage() != nil {
                    try save(runtime, to: output.appendingPathComponent("windows-\(index).png"))
                }
            }
        }
        runtime.forceStop()
        for _ in 0..<100 {
            if runtime.isStopped { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print("Diagnostic package: \(temporary.path)")
        return runtime.isStopped ? 0 : 1
    }

    private static func checkConcurrent(store: VMStore, first: VMRecord, configuration: WoAConfiguration, output: URL) async throws -> Int32 {
        var config = configuration
        config.cpuCount = 2; config.memoryGiB = 2
        let second = VMRecord(name: "Concurrent probe", kind: .windowsARM64, cpuCount: 2, memoryGiB: 2, diskGiB: 8, woaConfiguration: config)
        try store.create(second)
        let a = VMRuntime(record: first, directory: store.directory(for: first))
        let b = VMRuntime(record: second, directory: store.directory(for: second))
        defer { a.forceStop(); b.forceStop() }
        a.start(); b.start()
        for _ in 0..<240 {
            if a.woa?.displayView?.hasFrame == true && b.woa?.displayView?.hasFrame == true { break }
            if let error = a.errorMessage ?? b.errorMessage { throw AppFailure(error) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard a.woa?.displayView?.hasFrame == true, b.woa?.displayView?.hasFrame == true else { throw AppFailure("Concurrent SPICE frames timed out") }
        print("PASS: two simultaneous VM processes and SPICE displays")
        let before = Date()
        a.woa?.freezeForProbe()
        a.forceStop()
        for _ in 0..<80 {
            if a.isStopped { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard a.isStopped, b.isRunning else { throw AppFailure("Frozen VM kill failed or stopped its peer") }
        print("PASS: frozen QEMU SIGKILL in \(Date().timeIntervalSince(before))s; peer remains running")
        // An update triggered after the first client's teardown must still reach the second client.
        b.woa?.displayView?.client.key(0x150, down: true)
        b.woa?.displayView?.client.key(0x150, down: false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try save(b, to: output.appendingPathComponent("peer-after-kill.png"))
        b.forceStop()
        for _ in 0..<80 {
            if b.isStopped { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard b.isStopped else { throw AppFailure("Peer did not stop") }
        print("PASS: both VM sessions stopped independently")
        return 0
    }

    private static func save(_ runtime: VMRuntime, to url: URL) throws {
        guard let image = runtime.woa?.displayView?.client.currentImage() else { throw AppFailure("no frame to save") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw AppFailure("PNG encoding failed") }
        try data.write(to: url)
        print("saved \(url.path) \(image.width)x\(image.height)")
    }
}
