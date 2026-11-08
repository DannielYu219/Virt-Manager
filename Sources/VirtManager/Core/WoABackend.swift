import Foundation

/// Locations of the UTM fork components copied into our own app bundle at build time.
/// No runtime lookup of the separately installed UTM app is performed.
public struct WoARuntimeBundle {
    public let appURL: URL
    public var resources: URL { appURL.appendingPathComponent("Contents/Resources/WoA/qemu", isDirectory: true) }
    public var frameworks: URL { appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true) }
    public var qemuImage: URL { image("qemu-aarch64-softmmu") }
    public var qemu120Image: URL { frameworks.appendingPathComponent("qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu-120") }
    public var swtpmImage: URL { image("swtpm.0") }
    public var qemuImgImage: URL { image("qemu-img") }
    public var secureFirmwareCode: URL { resources.appendingPathComponent("edk2-aarch64-secure-code.fd") }
    public var firmwareCode: URL { resources.appendingPathComponent("edk2-aarch64-code.fd") }
    public var secureFirmwareVariables: URL { resources.appendingPathComponent("edk2-arm-secure-vars.fd") }
    public var firmwareVariables: URL { resources.appendingPathComponent("edk2-arm-vars.fd") }
    public var vulkanICD: URL { appURL.appendingPathComponent("Contents/Resources/WoA/vulkan/icd.d/MoltenVK_icd.json") }
    public var rendererServer: URL { appURL.appendingPathComponent("Contents/Helpers/QEMURenderServer") }
    public var version: String { "5.0.8" }
    public var guestToolsISO: URL { appURL.appendingPathComponent("Contents/Resources/WoA/utm-guest-tools-0.1.275.iso") }

    private func image(_ name: String) -> URL {
        frameworks.appendingPathComponent("\(name).framework/Versions/A/\(name)")
    }

    public static func locate(fileManager: FileManager = .default) -> WoARuntimeBundle? {
        let app = Bundle.main.bundleURL
        let runtime = WoARuntimeBundle(appURL: app)
        guard fileManager.isExecutableFile(atPath: runtime.qemuImage.path),
              fileManager.isExecutableFile(atPath: runtime.swtpmImage.path),
              fileManager.isReadableFile(atPath: runtime.secureFirmwareCode.path),
              fileManager.isReadableFile(atPath: runtime.vulkanICD.path) else { return nil }
        return runtime
    }

    public func nativeFramework(_ name: String) -> URL? {
        let url = frameworks.appendingPathComponent("\(name).framework/Versions/A/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func spiceImage(_ name: String) -> URL {
        frameworks.appendingPathComponent("\(name).framework/Versions/A/\(name)")
    }
}

/// Graphics capabilities shipped with this app. Feature presence is derived from this release's manifest.
public struct WoAGraphicsCapabilities: Equatable {
    public var hasGLDevice = true
    public var hasVenus = true
    public var hasBlob = true
    public var hasNeptune = true
    public var hasGuestVulkanICD = true
    public var hasDirectXBackend = true

    public func supports(_ mode: WoAGraphicsMode) -> Bool {
        switch mode {
        case .software: true
        case .utmVenus: hasGLDevice && hasVenus && hasBlob
        case .utmDirectX: hasGLDevice && hasNeptune && hasBlob && hasDirectXBackend
        }
    }

    public func unavailableReason(for mode: WoAGraphicsMode) -> String? {
        supports(mode) ? nil : (mode == .utmDirectX && !hasDirectXBackend
            ? "应用内没有 DirectX 宿主转换后端（D3DMetal/DXMT），已阻止启动黑屏配置。"
            : "应用内置的 UTM QEMU 缺少所选 GPU 功能。请重新安装当前版本。")
    }
}

public enum WoABackend {
    public static let guestToolsURL = URL(string: "https://getutm.app/downloads/utm-guest-tools-3d-latest.iso")!

    /// QEMU framework images are libraries, hosted by an entitled executable copied into Contents/Helpers.
    public static var launcherURL: URL? {
        let candidate = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/utm-qemu-launcher")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    public static func runtimeDirectory(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("virtmgr-\(id.uuidString.prefix(8).lowercased())", isDirectory: true)
    }

    public struct LaunchPlan: Equatable {
        public var qemu: [String]
        public var swtpm: [String]?
        public var spiceSocket: URL
        public var qmpSocket: URL
        public var tpmSocket: URL
        public var tpmState: URL
        public var environment: [String: String]
    }

    public static func capabilities(bundle: WoARuntimeBundle? = .locate()) -> WoAGraphicsCapabilities {
        guard let bundle else { return WoAGraphicsCapabilities(hasGLDevice: false, hasVenus: false, hasBlob: false, hasNeptune: false, hasGuestVulkanICD: false, hasDirectXBackend: false) }
        let probe = run(bundle, ["-device", "virtio-ramfb-gl,help"])
        return WoAGraphicsCapabilities(
            hasGLDevice: probe.contains("virtio-ramfb-gl"),
            hasVenus: probe.contains("venus"),
            hasBlob: probe.contains("blob"),
            hasNeptune: probe.contains("neptune"),
            hasGuestVulkanICD: FileManager.default.fileExists(atPath: bundle.vulkanICD.path),
            hasDirectXBackend: bundle.nativeFramework("d3dmetal-native") != nil || bundle.nativeFramework("dxmt-native") != nil)
    }

    private static func run(_ bundle: WoARuntimeBundle, _ arguments: [String]) -> String {
        guard let launcherURL else { return "" }
        let process = Process()
        process.executableURL = launcherURL
        process.arguments = [bundle.qemuImage.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env["DYLD_FRAMEWORK_PATH"] = bundle.frameworks.path
        env["DYLD_LIBRARY_PATH"] = bundle.frameworks.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public static func plan(configuration: WoAConfiguration, macAddress: String, runtime: URL, package: URL, uuid: UUID,
                            bundle: WoARuntimeBundle? = .locate(), launcher: URL? = launcherURL) throws -> LaunchPlan {
        #if !arch(arm64)
        throw WoAError.unsupportedHost("Windows ARM64 使用 HVF 硬件加速，需要 Apple Silicon 宿主机。")
        #endif
        guard let bundle else { throw WoAError.qemuUnavailable("应用内没有 WoA 运行时，请重新安装 Virt Manager。") }
        guard let launcher else { throw WoAError.qemuUnavailable("缺少 WoA QEMU 辅助程序，请重新安装 Virt Manager。") }
        try configuration.validate()
        if configuration.graphicsMode == .utmDirectX,
           bundle.nativeFramework("d3dmetal-native") == nil, bundle.nativeFramework("dxmt-native") == nil {
            throw WoAError.qemuUnavailable("DirectX 模式需要随 App 打包的 D3DMetal 或 DXMT 宿主后端。")
        }
        guard let diskImage = configuration.diskImage, let firmwareCode = configuration.firmwareCode,
              let firmwareVariables = configuration.firmwareVariables else {
            throw WoAError.invalid("Windows ARM64 需要磁盘镜像和 UEFI 固件文件。")
        }
        let spice = runtime.appendingPathComponent("spice.sock")
        let qmp = runtime.appendingPathComponent("qmp.sock")
        let tpmSocket = runtime.appendingPathComponent("tpm.sock")
        let tpmState = package.appendingPathComponent("TPM", isDirectory: true)
        guard spice.path.utf8.count < 100 else { throw WoAError.invalid("运行目录路径过长：\(runtime.path)") }

        var q = [launcher.path, configuration.displayRefreshHz == 120 ? bundle.qemu120Image.path : bundle.qemuImage.path, "-L", bundle.resources.path,
                 "-name", configuration.name, "-nodefaults", "-uuid", uuid.uuidString,
                 "-vga", "none", "-machine", "virt,highmem=on,gic-version=3",
                 "-accel", configuration.graphicsMode.usesGL ? "hvf,ipa-granule-size=0x1000" : "hvf", "-cpu", "host",
                 "-smp", String(configuration.cpuCount), "-m", String(configuration.memoryGiB * 1024),
                 "-rtc", "base=localtime",
                 "-drive", "if=pflash,format=raw,unit=0,file=\(firmwareCode.path),readonly=on",
                 "-drive", "if=pflash,format=raw,unit=1,file=\(firmwareVariables.path)",
                 "-qmp", "unix:\(qmp.path),server=on,wait=off",
                 "-device", "nec-usb-xhci,id=usb-bus", "-device", "usb-kbd,bus=usb-bus.0", "-device", "usb-tablet,bus=usb-bus.0",
                 "-drive", "if=none,media=disk,id=system,file=\(diskImage.path),format=raw,discard=unmap,detect-zeroes=unmap",
                 "-device", "nvme,drive=system,serial=virtmgr-\(uuid.uuidString.prefix(8).lowercased()),bootindex=1",
                 "-device", "virtio-rng-pci"]

        var cdIndex = 0
        func addCD(_ url: URL, bootIndex: Int?) {
            let id = "cd\(cdIndex)"
            cdIndex += 1
            q += ["-drive", "if=none,media=cdrom,id=\(id),file=\(url.path),format=raw,readonly=on",
                  "-device", "usb-storage,drive=\(id),removable=true" + (bootIndex.map { ",bootindex=\($0)" } ?? "")]
        }
        if let iso = configuration.installerISO { addCD(iso, bootIndex: 0) }
        addCD(configuration.driverISO ?? bundle.guestToolsISO, bootIndex: nil)
        // Legacy sharedDirectory options remain persisted, but Windows folder sharing is disabled.
        // Do not expose host paths through 9p/virtiofs; SPICE WebDAV is not implemented.

        q += ["-spice", "unix=on,addr=\(spice.path),disable-ticketing=on,image-compression=off,playback-compression=off,streaming-video=off,gl=\(configuration.graphicsMode.usesGL ? "es" : "off")",
              "-chardev", "spicevmc,id=vdagent,name=vdagent",
              "-device", "virtio-serial-pci,id=virtio-serial",
              "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0"]

        switch configuration.graphicsMode {
        case .software: q += ["-device", "virtio-ramfb,max_outputs=1,edid=on,xres=\(configuration.displayWidth),yres=\(configuration.displayHeight)"]
        case .utmVenus: q += ["-device", "virtio-ramfb-gl,max_outputs=1,edid=on,xres=\(configuration.displayWidth),yres=\(configuration.displayHeight),hostmem=8G,blob=true,venus=true,neptune=true"]
        case .utmDirectX: q += ["-device", "virtio-ramfb-gl,max_outputs=1,edid=on,xres=\(configuration.displayWidth),yres=\(configuration.displayHeight),hostmem=8G,blob=true,venus=true,neptune=true"]
        }
        switch configuration.networkMode {
        case .user, .userPortForward:
            let forwards = configuration.networkMode == .userPortForward ? configuration.networkPortForwards.map { "hostfwd=\($0)" } : []
            q += ["-netdev", (["user,id=net0"] + forwards).joined(separator: ","), "-device", "virtio-net-pci,netdev=net0,mac=\(macAddress)"]
        case .socket:
            if let path = configuration.networkSocketPath {
                q += ["-netdev", "stream,id=net0,server=off,addr.type=unix,addr.path=\(path.path.replacingOccurrences(of: ",", with: ",,"))", "-device", "virtio-net-pci,netdev=net0,mac=\(macAddress)"]
            }
        case .disconnected: break
        }
        if configuration.audioEnabled { q += ["-audiodev", "coreaudio,id=audio0", "-device", "intel-hda", "-device", "hda-output,audiodev=audio0"] }
        var swtpm: [String]?
        if configuration.tpmEnabled {
            swtpm = [launcher.path, bundle.swtpmImage.path, "--tpm2", "--tpmstate", "dir=\(tpmState.path)", "--ctrl", "type=unixio,path=\(tpmSocket.path)", "--terminate"]
            q += ["-chardev", "socket,id=chrtpm,path=\(tpmSocket.path)", "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-crb-device,tpmdev=tpm0"]
        }
        var env = ProcessInfo.processInfo.environment
        env["XDG_RUNTIME_DIR"] = runtime.path
        env["DYLD_FRAMEWORK_PATH"] = bundle.frameworks.path
        env["DYLD_LIBRARY_PATH"] = bundle.frameworks.path
        if configuration.graphicsMode.usesGL {
            env["ANGLE_DEFAULT_PLATFORM"] = "metal"
            env["VK_DRIVER_FILES"] = bundle.vulkanICD.path
            env["RENDER_SERVER_EXEC_PATH"] = bundle.rendererServer.path
        }
        // Windows viogpu3d uses Direct3D for desktop composition even when Venus is selected.
        if configuration.graphicsMode.usesGL {
            if let d3d = bundle.nativeFramework("d3dmetal-native") {
                env["NPT_BACKEND"] = "d3dmetal"
                env["D3DMETAL_FRAMEWORK_PATH"] = bundle.frameworks.appendingPathComponent("D3DMetal.framework/Versions/A/D3DMetal").path
                for key in ["NPT_D3D11_LIBRARY_PATH", "NPT_D3D12_LIBRARY_PATH", "NPT_DXGI_LIBRARY_PATH"] { env[key] = d3d.path }
                env["NPT_CAPSET_D3D12"] = "1"
            } else if let dxmt = bundle.nativeFramework("dxmt-native") {
                env["NPT_BACKEND"] = "dxmt"
                for key in ["NPT_D3D11_LIBRARY_PATH", "NPT_DXGI_LIBRARY_PATH"] { env[key] = dxmt.path }
            }
        }
        q += configuration.extraArguments.split(whereSeparator: \.isWhitespace).map(String.init)
        return LaunchPlan(qemu: q, swtpm: swtpm, spiceSocket: spice, qmpSocket: qmp, tpmSocket: tpmSocket,
                          tpmState: tpmState, environment: env)
    }
}
