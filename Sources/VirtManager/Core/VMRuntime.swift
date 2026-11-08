import AppKit
import Combine
import Darwin
import Foundation
import Virtualization

private struct MacRequirements: Codable {
    let minimumCPUCount: Int
    let minimumMemorySize: UInt64
}

@MainActor
public final class VMRuntime: NSObject, ObservableObject, @preconcurrency VZVirtualMachineDelegate {
    @Published public private(set) var machine: VZVirtualMachine? {
        didSet {
            stateObservation = machine?.observe(\.state, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
        }
    }
    private var stateObservation: NSKeyValueObservation?
    private var executionLock: VMExecutionLock?
    @Published public private(set) var status = "Stopped"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var isBusy = false

    public private(set) var record: VMRecord
    public let directory: URL
    public var onRecordChange: ((VMRecord) -> Void)?
    private var installer: VZMacOSInstaller?
    private var progressObservation: NSKeyValueObservation?
    private var minimumCPUCount = 1
    private var minimumMemorySize: UInt64 = 0
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var woa: WoARuntime?
    private var operationGeneration = UUID()

    public init(record: VMRecord, directory: URL) {
        self.record = record
        self.directory = directory
        super.init()
    }

    public var isStopped: Bool { record.kind == .windowsARM64 ? (woa?.isStopped ?? true) : (machine?.state == .stopped || machine == nil) }
    public var isRunning: Bool { record.kind == .windowsARM64 ? (woa?.isRunning ?? false) : machine?.state == .running }
    public var isPaused: Bool { record.kind == .windowsARM64 ? (woa?.isPaused ?? false) : machine?.state == .paused }
    /// Identity of whatever currently provides pixels: the AVF machine or the WoA SPICE view.
    var displayIdentity: ObjectIdentifier? {
        if record.kind == .windowsARM64 { return woa?.displayView.map(ObjectIdentifier.init) }
        return machine.map(ObjectIdentifier.init)
    }
    public var canEdit: Bool { isStopped && !isBusy }
    public var canEditLiveSettings: Bool { (isRunning || isPaused) && !isBusy }

    public func updateSettingsWhileRunning(_ updated: VMRecord) async throws {
        guard canEditLiveSettings else { throw RuntimeError.invalid("只有运行中的虚拟机可以在线调整支持的设置。") }
        guard updated.id == record.id, updated.kind == record.kind else { throw RuntimeError.invalid("不能在线修改虚拟机身份或系统类型。") }
        isBusy = true
        defer { isBusy = false }
        if record.kind == .windowsARM64 {
            guard let woa, let options = record.resolvedWoAConfiguration(in: directory), let next = updated.resolvedWoAConfiguration(in: directory) else {
                throw RuntimeError.invalid("Windows ARM64 配置缺失。")
            }
            try next.validate()
            guard record.cpuCount == updated.cpuCount, record.memoryGiB == updated.memoryGiB,
                  record.diskGiB == updated.diskGiB, record.macAddress == updated.macAddress,
                  record.audioEnabled == updated.audioEnabled, options.graphicsMode == next.graphicsMode,
                  options.tpmEnabled == next.tpmEnabled, options.extraArguments == next.extraArguments,
                  options.displayRefreshHz == next.displayRefreshHz else {
                throw RuntimeError.invalid("CPU、内存、磁盘、网卡、音频、图形模式、刷新率及启动参数需关机后修改。")
            }
            guard record.sharedDirectoryPath == updated.sharedDirectoryPath,
                  record.sharedDirectoryReadOnly == updated.sharedDirectoryReadOnly,
                  options.sharedDirectory == next.sharedDirectory,
                  options.sharedDirectoryReadOnly == next.sharedDirectoryReadOnly else {
                throw RuntimeError.invalid("当前版本尚未实现 Windows SPICE WebDAV 文件夹共享。")
            }
            if options.networkMode != next.networkMode || options.networkPortForwards != next.networkPortForwards || options.networkSocketPath != next.networkSocketPath {
                throw RuntimeError.invalid("Windows 网络设置需关机后修改。")
            }
            if options.displayWidth != next.displayWidth || options.displayHeight != next.displayHeight || options.displayRefreshHz != next.displayRefreshHz {
                try await woa.reconfigureDisplay(width: next.displayWidth, height: next.displayHeight, refreshHz: next.displayRefreshHz)
            }
            if options.usbAssignments != next.usbAssignments || options.autoConnectNewUSBDevices != next.autoConnectNewUSBDevices {
                woa.setUSBAssignments(next.usbAssignments, autoConnect: next.autoConnectNewUSBDevices)
            }
        } else {
            if record.networkEnabled != updated.networkEnabled ||
                record.sharedDirectoryPath != updated.sharedDirectoryPath ||
                record.sharedDirectoryReadOnly != updated.sharedDirectoryReadOnly ||
                record.displayWidth != updated.displayWidth || record.displayHeight != updated.displayHeight ||
                record.audioEnabled != updated.audioEnabled || record.clipboardEnabled != updated.clipboardEnabled ||
                record.rosettaEnabled != updated.rosettaEnabled {
                throw RuntimeError.invalid("Virtualization.framework 不支持这些 Linux/macOS 设置的在线修改；请关机后保存。")
            }
        }
        let previous = record
        record = updated
        do { try persistRecord(); onRecordChange?(record) }
        catch { record = previous; throw error }
    }

    public func validate() throws {
        if record.kind == .windowsARM64 {
            _ = try makeWoAPlan()
            return
        }
        guard (1...64).contains(record.cpuCount) else { throw RuntimeError.invalid("CPU count must be between 1 and 64.") }
        guard (1...1024).contains(record.memoryGiB) else { throw RuntimeError.invalid("Memory must be between 1 and 1024 GiB.") }
        guard (1...16384).contains(record.diskGiB) else { throw RuntimeError.invalid("Disk must be between 1 and 16384 GiB.") }
        guard (1...16384).contains(record.displayWidth), (1...16384).contains(record.displayHeight) else {
            throw RuntimeError.invalid("Display dimensions must be between 1 and 16384 pixels.")
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Disk.img").path) else {
            throw RuntimeError.invalid("The machine disk image is missing.")
        }
        if record.kind == .macOS {
            if record.clipboardEnabled { throw RuntimeError.invalid("当前剪贴板共享仅支持安装了 SPICE agent 的 Linux 客户机，暂不支持 macOS 客户机。") }
            if record.rosettaEnabled { throw RuntimeError.invalid("Rosetta support is only available for Linux guests.") }
            #if !arch(arm64)
            throw RuntimeError.invalid("macOS guests require an Apple-silicon host.")
            #else
            if !record.macInstalled {
                guard let path = record.installerPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                    throw RuntimeError.invalid("Choose a local macOS IPSW restore image before installation.")
                }
                return
            }
            if record.sharedDirectoryPath != nil { throw RuntimeError.invalid("Shared directories are unsupported for macOS guests.") }
            #endif
        } else if record.rosettaEnabled {
            #if arch(arm64)
            guard #available(macOS 13.0, *) else { throw RuntimeError.invalid("Linux Rosetta requires macOS 13 or later on Apple silicon.") }
            guard LinuxRosettaSupport.isInstalled else { throw RuntimeError.invalid(LinuxRosettaSupport.statusText) }
            #else
            throw RuntimeError.invalid("Linux Rosetta requires an Apple-silicon host.")
            #endif
        }
        if record.kind == .macOS, !record.macInstalled { throw RuntimeError.invalid("Prepare macOS installation using the restore image before validation.") }
        try makeConfiguration().validate()
    }

    public func start() {
        guard !isBusy, canEdit else { return }
        operationGeneration = UUID()
        isBusy = true
        Task { await performStart() }
    }

    public func pause() {
        if record.kind == .windowsARM64 {
            guard !isBusy, let woa else { return }
            isBusy = true
            Task {
                let generation = operationGeneration
                do { try await woa.pause(); guard generation == operationGeneration else { return }; status = "Paused"; errorMessage = nil } catch { if generation == operationGeneration { report(error) } }
                isBusy = false
            }
            return
        }
        guard let machine, machine.state == .running, !isBusy else { return }
        isBusy = true
        Task {
            do { try await machine.pause(); status = "Paused"; errorMessage = nil }
            catch { report(error) }
            isBusy = false
        }
    }

    public func resume() {
        if record.kind == .windowsARM64 {
            guard !isBusy, let woa else { return }
            isBusy = true
            Task {
                let generation = operationGeneration
                do { try await woa.resume(); guard generation == operationGeneration else { return }; status = "Running"; errorMessage = nil } catch { if generation == operationGeneration { report(error) } }
                isBusy = false
            }
            return
        }
        guard let machine, machine.state == .paused, !isBusy else { return }
        isBusy = true
        Task {
            do { try await machine.resume(); status = "Running"; errorMessage = nil }
            catch { report(error) }
            isBusy = false
        }
    }

    public func requestStop() {
        if record.kind == .windowsARM64 {
            guard !isBusy, let woa, isRunning || isPaused else { return }
            let generation = operationGeneration
            Task {
                do {
                    try await woa.requestStop()
                    guard generation == operationGeneration else { return }
                    status = "Stopping"; errorMessage = nil
                } catch { if generation == operationGeneration { report(error) } }
            }
            return
        }
        guard let machine, !isBusy, machine.state != .stopped else { return }
        do {
            try machine.requestStop()
            status = "Stopping"
            errorMessage = nil
        } catch {
            report(error)
        }
    }

    public func forceStop() {
        if record.kind == .windowsARM64 {
            guard let woa, !woa.isStopped else { return }
            operationGeneration = UUID()
            status = "Stopping"
            woa.forceStop()
            return
        }
        guard let machine, machine.state != .stopped else { return }
        operationGeneration = UUID()
        isBusy = true
        status = "Stopping"
        Task {
            do { try await machine.stop(); resetStoppedState() }
            catch { report(error) }
            isBusy = false
        }
    }

    public func installMacOS() {
        guard record.kind == .macOS, !record.macInstalled, !isBusy else { return }
        isBusy = true
        progress = 0
        status = "Preparing macOS installer"
        Task { await performMacInstall() }
    }

    private func performStart() async {
        let generation = operationGeneration
        do {
            executionLock = try VMExecutionLock(directory: directory)
            try validate()
            if record.kind == .windowsARM64 {
                let (plan, runtime) = try makeWoAPlan()
                guard let runtimeBundle = WoARuntimeBundle.locate() else { throw RuntimeError.invalid("WoA 运行组件缺失，请重新安装 Virt Manager。") }
                let session = WoARuntime()
                session.onUSBError = { [weak self] message in self?.errorMessage = message }
                session.onChange = { [weak self] in self?.objectWillChange.send() }
                session.onExit = { [weak self] status, detail in
                    guard let self else { return }
                    self.operationGeneration = UUID()
                    self.woa = nil
                    self.executionLock = nil
                    self.isBusy = false
                    if status == 0 || detail == nil {
                        self.status = "Stopped"
                    } else {
                        self.status = "Error"
                        self.errorMessage = "QEMU 异常退出（\(status)）：\(detail ?? "")"
                    }
                }
                woa = session
                status = "Starting"
                do {
                    try await session.start(plan: plan, runtime: runtime, package: directory, bundle: runtimeBundle)
                } catch {
                    guard generation == operationGeneration else { return }
                    woa = nil
                    throw error
                }
                guard generation == operationGeneration else { return }
                status = "Running"
                errorMessage = nil
                isBusy = false
                return
            }
            if record.kind == .macOS && !record.macInstalled {
                throw RuntimeError.invalid("macOS is not installed yet. Use installMacOS() with the configured IPSW.")
            }
            let config = try makeConfiguration()
            try config.validate()
            let vm = VZVirtualMachine(configuration: config, queue: .main)
            vm.delegate = self
            machine = vm
            try await vm.start()
            guard generation == operationGeneration else { return }
            status = "Running"
            errorMessage = nil
        } catch {
            guard generation == operationGeneration else { return }
            machine = nil
            executionLock = nil
            report(error)
        }
        isBusy = false
    }

    private func makeWoAPlan() throws -> (WoABackend.LaunchPlan, URL) {
        guard let options = record.resolvedWoAConfiguration(in: directory) else { throw RuntimeError.invalid("Windows ARM64 配置缺失。") }
        let runtime = WoABackend.runtimeDirectory(for: record.id)
        do {
            return (try WoABackend.plan(configuration: options, macAddress: record.macAddress, runtime: runtime, package: directory, uuid: record.id), runtime)
        } catch { throw RuntimeError.invalid(error.localizedDescription) }
    }

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(record.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let (memory, overflow) = UInt64(record.memoryGiB).multipliedReportingOverflow(by: 1024 * 1024 * 1024)
        guard !overflow else { throw RuntimeError.invalid("Memory size is too large.") }
        config.memorySize = max(memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        if record.kind == .linux {
            let platform = VZGenericPlatformConfiguration()
            platform.machineIdentifier = try loadOrCreateGenericIdentifier()
            config.platform = platform
            config.bootLoader = VZEFIBootLoader()
            let efiURL = directory.appendingPathComponent("EFIVariableStore")
            if !FileManager.default.fileExists(atPath: efiURL.path) {
                _ = try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
            }
            let efi = VZEFIVariableStore(url: efiURL)
            (config.bootLoader as? VZEFIBootLoader)?.variableStore = efi
            config.storageDevices = [try diskAttachment(directory.appendingPathComponent("Disk.img"))]
            if let path = record.installerPath, !path.isEmpty {
                let iso = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: true)
                config.storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: iso))
            }
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: record.displayWidth, heightInPixels: record.displayHeight)]
            config.graphicsDevices = [graphics]
        } else {
            #if arch(arm64)
            config.platform = try makeMacPlatform()
            config.bootLoader = VZMacOSBootLoader()
            config.storageDevices = [try diskAttachment(directory.appendingPathComponent("Disk.img"))]
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: record.displayWidth, heightInPixels: record.displayHeight, pixelsPerInch: 144)]
            config.graphicsDevices = [graphics]
            #else
            throw RuntimeError.invalid("macOS guests require an Apple-silicon host.")
            #endif
        }
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        if record.networkEnabled {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            network.macAddress = macAddress(record.macAddress)
            config.networkDevices = [network]
        }
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if record.kind == .linux {
            config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            if let path = record.sharedDirectoryPath, !path.isEmpty {
                let shared = VZVirtioFileSystemDeviceConfiguration(tag: "share")
                shared.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: path, isDirectory: true), readOnly: record.sharedDirectoryReadOnly))
                config.directorySharingDevices.append(shared)
            }
            if record.rosettaEnabled {
                #if arch(arm64)
                guard #available(macOS 13.0, *), LinuxRosettaSupport.isInstalled else {
                    throw RuntimeError.invalid(LinuxRosettaSupport.statusText)
                }
                let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                rosetta.share = try VZLinuxRosettaDirectoryShare()
                config.directorySharingDevices.append(rosetta)
                #else
                throw RuntimeError.invalid("Linux Rosetta requires an Apple-silicon host.")
                #endif
            }
        }
        if record.audioEnabled {
            let audio = VZVirtioSoundDeviceConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            audio.streams = [output]
            config.audioDevices = [audio]
        }
        if record.clipboardEnabled {
            guard record.kind == .linux else { throw RuntimeError.invalid("剪贴板同步基础版仅支持 Linux 客户机。") }
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            port.isConsole = false
            let attachment = VZSpiceAgentPortAttachment()
            attachment.sharesClipboard = true
            port.attachment = attachment
            let console = VZVirtioConsoleDeviceConfiguration()
            console.ports[0] = port
            config.consoleDevices = [console]
        }
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = try VZFileSerialPortAttachment(url: directory.appendingPathComponent("serial.log"), append: true)
        config.serialPorts = [serial]
        return config
    }

    private func diskAttachment(_ url: URL) throws -> VZVirtioBlockDeviceConfiguration {
        VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false))
    }

    private func loadOrCreateGenericIdentifier() throws -> VZGenericMachineIdentifier {
        let url = directory.appendingPathComponent("MachineIdentifier")
        if let data = try? Data(contentsOf: url), let identifier = VZGenericMachineIdentifier(dataRepresentation: data) { return identifier }
        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: url, options: .atomic)
        return identifier
    }

    #if arch(arm64)
    private func makeMacPlatform() throws -> VZMacPlatformConfiguration {
        let platform = VZMacPlatformConfiguration()
        let modelURL = directory.appendingPathComponent("HardwareModel.bin")
        let identifierURL = directory.appendingPathComponent("MachineIdentifier.bin")
        guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: modelURL)), model.isSupported,
              let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: identifierURL)) else {
            throw RuntimeError.invalid("macOS hardware identity is missing or unsupported. Prepare from a local IPSW first.")
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Requirements.json").path) {
            let minima = try JSONDecoder().decode(MacRequirements.self, from: Data(contentsOf: directory.appendingPathComponent("Requirements.json")))
            guard record.cpuCount >= minima.minimumCPUCount,
                  UInt64(record.memoryGiB) * 1024 * 1024 * 1024 >= minima.minimumMemorySize else {
                throw RuntimeError.invalid("Configured CPU or memory is below this macOS IPSW's minimum requirements.")
            }
        }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: directory.appendingPathComponent("AuxiliaryStorage"))
        return platform
    }
    #endif

    private func performMacInstall() async {
        #if arch(arm64)
        do {
            executionLock = try VMExecutionLock(directory: directory)
            guard let path = record.installerPath, !path.isEmpty else { throw RuntimeError.invalid("A local macOS IPSW is required.") }
            let image = try await loadRestoreImage(path)
            guard let requirements = image.mostFeaturefulSupportedConfiguration else { throw RuntimeError.invalid("The IPSW has no configuration supported by this host.") }
            guard record.cpuCount >= requirements.minimumSupportedCPUCount else { throw RuntimeError.invalid("This IPSW requires at least \(requirements.minimumSupportedCPUCount) CPUs.") }
            let memory = UInt64(record.memoryGiB) * 1024 * 1024 * 1024
            guard memory >= requirements.minimumSupportedMemorySize else { throw RuntimeError.invalid("This IPSW requires at least \(requirements.minimumSupportedMemorySize / (1024 * 1024 * 1024)) GiB RAM.") }
            let modelURL = directory.appendingPathComponent("HardwareModel.bin")
            let identifierURL = directory.appendingPathComponent("MachineIdentifier.bin")
            let minimaURL = directory.appendingPathComponent("Requirements.json")
            let model: VZMacHardwareModel
            let identifier: VZMacMachineIdentifier
            if FileManager.default.fileExists(atPath: modelURL.path) || FileManager.default.fileExists(atPath: identifierURL.path) {
                guard let savedModel = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: modelURL)), savedModel.isSupported,
                      let savedIdentifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: identifierURL)),
                      savedModel.dataRepresentation == requirements.hardwareModel.dataRepresentation else {
                    throw RuntimeError.invalid("Saved macOS identity is incompatible with this IPSW.")
                }
                model = savedModel
                identifier = savedIdentifier
            } else {
                model = requirements.hardwareModel
                identifier = VZMacMachineIdentifier()
                try model.dataRepresentation.write(to: modelURL, options: .withoutOverwriting)
                try identifier.dataRepresentation.write(to: identifierURL, options: .withoutOverwriting)
            }
            if !FileManager.default.fileExists(atPath: minimaURL.path) {
                let minima = MacRequirements(minimumCPUCount: requirements.minimumSupportedCPUCount,
                                             minimumMemorySize: requirements.minimumSupportedMemorySize)
                try JSONEncoder().encode(minima).write(to: minimaURL, options: .withoutOverwriting)
            }
            minimumCPUCount = requirements.minimumSupportedCPUCount
            minimumMemorySize = requirements.minimumSupportedMemorySize
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("AuxiliaryStorage").path) {
                _ = try VZMacAuxiliaryStorage(creatingStorageAt: directory.appendingPathComponent("AuxiliaryStorage"), hardwareModel: model, options: [])
            }
            _ = identifier
            try makeInstallationDiskIfNeeded()
            let config = try makeConfiguration()
            try config.validate()
            let vm = VZVirtualMachine(configuration: config, queue: .main)
            vm.delegate = self
            machine = vm
            let activeInstaller = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: URL(fileURLWithPath: path))
            installer = activeInstaller
            progressObservation = activeInstaller.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in self?.progress = item.fractionCompleted }
            }
            status = "Installing macOS"
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                activeInstaller.install { continuation.resume(with: $0) }
            }
            record.macInstalled = true
            try persistRecord()
            onRecordChange?(record)
            progress = 1
            errorMessage = nil
            if vm.state == .running {
                status = "Running"
            } else {
                resetStoppedState()
                status = "Ready"
            }
            installer = nil
            progressObservation = nil
        } catch {
            if let vm = machine, vm.canStop { try? await vm.stop() }
            resetStoppedState()
            installer = nil
            progressObservation = nil
            report(error)
        }
        isBusy = false
        #else
        report(RuntimeError.invalid("macOS guests require an Apple-silicon host."))
        isBusy = false
        #endif
    }

    #if arch(arm64)
    private func loadRestoreImage(_ path: String) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: URL(fileURLWithPath: path)) { continuation.resume(with: $0) }
        }
    }

    private func makeInstallationDiskIfNeeded() throws {
        let url = directory.appendingPathComponent("Disk.img")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RuntimeError.invalid("Cannot create macOS disk: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let size = Int64(record.diskGiB) * 1024 * 1024 * 1024
        guard ftruncate(fd, off_t(size)) == 0 else { throw RuntimeError.invalid("Cannot size macOS disk image.") }
    }
    #endif

    private func macAddress(_ string: String) -> VZMACAddress {
        VZMACAddress(string: string) ?? VZMACAddress(string: "02:00:00:00:00:01")!
    }

    private func persistRecord() throws {
        try VMPackage.write(record: record, to: directory)
    }

    private func report(_ error: Error) { errorMessage = error.localizedDescription; status = "Error" }
    private func resetStoppedState() {
        machine = nil
        executionLock = nil
        status = "Stopped"
        stopContinuation?.resume()
        stopContinuation = nil
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard virtualMachine === machine else { return }
        if installer != nil {
            report(error)
            return
        }
        resetStoppedState()
        report(error)
        isBusy = false
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard virtualMachine === machine else { return }
        if installer != nil {
            status = "Installer VM stopped"
            return
        }
        resetStoppedState()
        isBusy = false
    }

    public enum RuntimeError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
    }
}
