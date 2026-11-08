import AppKit
import Foundation
import Darwin

/// Runs one Windows on ARM64 guest: swtpm, UTM's QEMU (HVF), a QMP control channel and the SPICE display.
@MainActor
final class WoARuntime {
    enum Phase: Equatable { case stopped, starting, running, paused, stopping }

    private(set) var phase: Phase = .stopped
    private(set) var displayView: WoADisplayView?
    var onChange: (() -> Void)?
    /// Called once when QEMU exits: exit status and a short diagnostic if it failed.
    var onExit: ((Int32, String?) -> Void)?

    private let qemu = WoAProcess()
    private let tpm = WoAProcess()
    private let qmp = QMPClient()
    private let client = WoASpiceClient()
    private var plan: WoABackend.LaunchPlan?
    private var runtimeDirectory: URL?
    private var logURL: URL?
    private var spiceTask: Task<Void, Never>?
    private var startCancelled = false
    private var usbInventory: WoAUSBInventory?
    private var usbAttached = Set<String>()
    private var usbDeviceIDs: [String: String] = [:]
    var onUSBError: ((String) -> Void)?
    private static var usbOwners: [String: UUID] = [:]
    private let usbOwner = UUID()
    private var usbTasks: [Task<Void, Never>] = []
    private var usbAutoConnect = false
    private var usbSelections: [WoAUSBSelection] = []

    var isRunning: Bool { phase == .running }
    var isPaused: Bool { phase == .paused }
    var isStopped: Bool { phase == .stopped }

    func start(plan: WoABackend.LaunchPlan, runtime: URL, package: URL, bundle: WoARuntimeBundle) async throws {
        guard phase == .stopped else { return }
        startCancelled = false
        phase = .starting
        onChange?()
        do {
            self.plan = plan
            runtimeDirectory = runtime
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: runtime)
            try fileManager.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.createDirectory(at: plan.tpmState, withIntermediateDirectories: true)
            let log = package.appendingPathComponent("qemu.log")
            try? fileManager.removeItem(at: log)
            logURL = log

            if let swtpm = plan.swtpm {
                tpm.onExit = { _ in }
                try tpm.start(command: swtpm, log: package.appendingPathComponent("swtpm.log"))
                guard await waitForFile(plan.tpmSocket, timeout: 10, alive: { [tpm] in tpm.isRunning }) else {
                    throw WoAError.invalid("swtpm 未能启动，TPM 套接字没有出现。详见包内 swtpm.log。")
                }
            }

            qemu.onExit = { [weak self] status in self?.qemuExited(status: status) }
            try qemu.start(command: plan.qemu, log: log, environment: plan.environment)
            guard await waitForFile(plan.qmpSocket, timeout: 20, alive: { [qemu] in qemu.isRunning }),
                  await waitForFile(plan.spiceSocket, timeout: 20, alive: { [qemu] in qemu.isRunning }) else {
                let tail = tailOfLog() ?? "QEMU 未能在期限内就绪。"
                forceStopProcesses()
                throw WoAError.invalid(tail)
            }
            if startCancelled { throw CancellationError() }
            try await qmp.connect(path: plan.qmpSocket.path)
            if startCancelled { throw CancellationError() }
            client.clipboardIntegrationEnabled = !CommandLine.arguments.contains("--woa-probe")
            try client.open(socket: plan.spiceSocket, frameworks: bundle.frameworks)
            let record = try? VMPackage.read(from: package)
            client.configurePresentation(hz: record?.woaConfiguration?.displayRefreshHz ?? 60)
            displayView = WoADisplayView(client: client, preferredResolution: CGSize(width: record?.displayWidth ?? 1920, height: record?.displayHeight ?? 1200))
            phase = .running
            if let options = record?.woaConfiguration {
                usbAutoConnect = options.autoConnectNewUSBDevices
                usbSelections = options.usbAssignments
                let inventory = WoAUSBInventory()
                usbInventory = inventory
                inventory.startPolling { [weak self] devices in
                    guard let self else { return }
                    let present = Set(inventory.devices.map(\.id))
                    for removed in self.usbAttached.subtracting(present) {
                        if let id = self.usbDeviceIDs.removeValue(forKey: removed) {
                            Task { _ = try? await self.qmp.execute("device_del", arguments: ["id": id]) }
                        }
                        self.usbAttached.remove(removed)
                        Self.usbOwners[removed] = nil
                    }
                    for device in devices where self.usbAutoConnect || self.usbSelections.contains(where: { $0.matches(device) }) {
                        self.attachUSB(device)
                    }
                }
            }
            onChange?()
        } catch {
            forceStopProcesses()
            cleanup()
            phase = .stopped
            onChange?()
            throw error
        }
    }

    func reconfigureDisplay(width: Int, height: Int, refreshHz: Int) async throws {
        guard phase == .running || phase == .paused else { throw WoAError.invalid("虚拟机未运行。") }
        guard width >= 640, height >= 480 else { throw WoAError.invalid("显示分辨率无效。") }
        guard client.agentConnected else { throw WoAError.invalid("在线调整分辨率需要已连接的 SPICE Guest Agent。") }
        // SPICE owns display negotiation. Starting a VNC listener is unrelated
        // and can fail or expose an unnecessary host service.
        client.configurePresentation(hz: refreshHz)
        displayView?.setPreferredResolution(width: width, height: height)
    }

    func setSharedDirectory(_ path: String?, readOnly: Bool) async throws {
        throw WoAError.invalid("当前版本尚未实现 Windows SPICE WebDAV 共享；9p/virtiofs 不适用于 Windows 客户机。")
    }

    func setUSBAssignments(_ selections: [WoAUSBSelection], autoConnect: Bool) {
        guard phase == .running || phase == .paused else { return }
        let options = Set(selections)
        usbAutoConnect = autoConnect
        usbSelections = selections
        let arguments = options.map { $0.qemuArguments }.filter { !$0.isEmpty }
        _ = arguments
        for device in usbInventory?.devices ?? [] where options.contains(where: { $0.matches(device) }) {
            attachUSB(device)
        }
        if autoConnect {
            for device in usbInventory?.devices ?? [] where !options.contains(where: { $0.matches(device) }) {
                attachUSB(device)
            }
        }
        for selection in Array(usbAttached) where !options.contains(where: { $0.key == selection }) && !(autoConnect && usbInventory?.devices.first(where: { $0.id == selection }) != nil) {
            detachUSB(selection)
        }
    }

    func reconfigureNetwork(_ configuration: WoAConfiguration, macAddress: String) async throws {
        // This machine has no verified hotplug/rollback contract for its boot NIC.
        // Never resume a paused guest or partially remove its network here.
        throw WoAError.invalid("Windows 网络设置需关机后修改；当前版本不支持安全的在线网络重配。")
    }

    private func detachUSB(_ key: String) {
        guard let id = usbDeviceIDs.removeValue(forKey: key) else { return }
        usbAttached.remove(key)
        Self.usbOwners[key] = nil
        usbTasks.append(Task { _ = try? await qmp.execute("device_del", arguments: ["id": id]) })
    }

    func pause() async throws {
        guard phase == .running else { return }
        try await qmp.execute("stop")
        guard !startCancelled else { return }
        phase = .paused
        onChange?()
    }

    func resume() async throws {
        guard phase == .paused else { return }
        try await qmp.execute("cont")
        guard !startCancelled else { return }
        phase = .running
        onChange?()
    }

    /// ACPI power button; Windows performs a clean shutdown.
    func requestStop() async throws {
        guard phase == .running || phase == .paused else { return }
        if phase == .paused { try await qmp.execute("cont") }
        try await qmp.execute("system_powerdown")
        guard !startCancelled else { return }
        phase = .stopping
        onChange?()
    }

    func dumpEDIDForProbe(to url: URL) async throws {
        // QEMU emits a binary EDID for its current virtual monitor via the HMP info command.
        let result = try await qmp.execute("human-monitor-command", arguments: ["command-line": "info qtree"])
        try String(describing: result).write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    /// Developer probe only: suspend QEMU to simulate a completely unresponsive monitor.
    func freezeForProbe() {
        if let pid = qemu.processIdentifier { kill(pid, SIGSTOP) }
    }

    func forceStop() {
        guard phase != .stopped else { return }
        startCancelled = true
        phase = .stopping
        // Emergency stop must never wait for a frozen QMP queue.
        forceStopProcesses()
        onChange?()
    }

    private func forceStopProcesses() {
        if qemu.isRunning { qemu.forceStop() }
        if tpm.isRunning { tpm.forceStop() }
    }

    private func qemuExited(status: Int32) {
        let wasStopping = phase == .stopping
        let tail = status != 0 && !wasStopping ? tailOfLog() : nil
        if tpm.isRunning { tpm.forceStop() }
        cleanup()
        phase = .stopped
        usbDeviceIDs.removeAll()
        onChange?()
        onExit?(status, tail)
    }

    private func attachUSB(_ device: WoAUSBDevice) {
        guard !usbAttached.contains(device.id), Self.usbOwners[device.id] == nil else { return }
        Self.usbOwners[device.id] = usbOwner
        usbAttached.insert(device.id)
        let id = "hostusb-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var arguments: [String: Any] = ["driver": "usb-host", "id": id, "bus": "usb-bus.0"]
        if let vendor = device.vendorID, let product = device.productID {
            arguments["vendorid"] = vendor; arguments["productid"] = product
        }
        if let address = device.address { arguments["hostaddr"] = address }
        if let bus = device.bus { arguments["hostbus"] = bus }
        usbTasks.append(Task { [weak self] in
            guard let self, !Task.isCancelled, self.phase == .running else { return }
            do {
                try await self.qmp.execute("device_add", arguments: arguments)
                self.usbDeviceIDs[device.id] = id
            }
            catch {
                if Self.usbOwners[device.id] == self.usbOwner { Self.usbOwners[device.id] = nil }
                self.usbAttached.remove(device.id)
                self.onUSBError?("USB \(device.name)：\(error.localizedDescription)")
            }
        })
    }

    private func cleanup() {
        usbInventory?.stopPolling()
        usbInventory = nil
        for key in usbAttached where Self.usbOwners[key] == usbOwner { Self.usbOwners[key] = nil }
        usbAttached.removeAll()
        usbTasks.forEach { $0.cancel() }; usbTasks.removeAll()
        spiceTask?.cancel()
        displayView?.setWindowActive(false)
        client.close()
        qmp.disconnect()
        displayView = nil
        if let runtimeDirectory { try? FileManager.default.removeItem(at: runtimeDirectory) }
        runtimeDirectory = nil
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval, alive: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if startCancelled { return false }
            if FileManager.default.fileExists(atPath: url.path) { return true }
            if !alive() { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func tailOfLog() -> String? {
        guard let logURL, let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: length > 1200 ? length - 1200 : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data.suffix(1200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
