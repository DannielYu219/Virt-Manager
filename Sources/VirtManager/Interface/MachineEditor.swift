import SwiftUI
import Virtualization

struct MachineEditor: View {
    @ObservedObject var model: AppModel
    let existing: VMRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VMRecord()
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var installingRosetta = false
    @State private var rosettaStatus = LinuxRosettaSupport.statusText
    @State private var resolutions: [DisplayResolution] = []
    @State private var selectedResolution = "1920x1200"
    @State private var storageParent: URL?
    @State private var woaRuntime: WoARuntimeBundle?
    @State private var woaGPU: WoAGraphicsMode = .software
    @State private var woaDriverISO: String?
    @State private var woaTPM = true
    @State private var woaDisplayRefreshHz = 60
    @State private var woaExtraArguments = ""
    @State private var woaUSBAssignments: Set<WoAUSBSelection> = []
    @State private var woaAutoConnectUSB = false
    @State private var woaNetworkMode: WoANetworkMode = .user
    @State private var woaPortForwards = ""
    @State private var woaSocketPath: String?
    @State private var isLiveEditing = false
    @StateObject private var woaUSBInventory = WoAUSBInventory()
    @State private var woaCapabilities = WoAGraphicsCapabilities()
    private var woaGPUDescription: String { woaGPU.detail }
    private var isMac: Bool { draft.kind == .macOS }
    private var isWindows: Bool { draft.kind == .windowsARM64 }
    private var maxCPUs: Int { min(64, VZVirtualMachineConfiguration.maximumAllowedCPUCount) }
    private var maxMemory: Int { min(1024, max(1, Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024 * 1024)))) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(existing == nil ? "新的工作空间" : isLiveEditing ? "运行中设置" : "虚拟机设置").font(.system(size: 25, weight: .medium))
                    Text(isLiveEditing ? "显示与设备分配将尝试即时生效；网络、系统资源和固件需关机修改。" : "配置将在下次启动时生效。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").fontWeight(.bold) }.buttonStyle(PillButtonStyle())
            }.padding(26)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if existing == nil {
                        HStack(spacing: 12) {
                            systemChoice("Linux", subtitle: "EFI · ISO 安装映像", symbol: "terminal", kind: .linux)
                            systemChoice("Windows ARM64", subtitle: "WoA · UTM QEMU", symbol: "windows.logo", kind: .windowsARM64)
                            systemChoice("macOS", subtitle: "Apple Silicon · IPSW", symbol: "apple.logo", kind: .macOS)
                        }
                    }
                    SectionPanel(title: "基本信息", symbol: "square.text.square") {
                        HStack {
                            Text("名称").frame(width: 90, alignment: .leading)
                            TextField("虚拟机名称", text: $draft.name).textFieldStyle(.plain)
                                .padding(.horizontal, 15).padding(.vertical, 9).background(.quaternary.opacity(0.45), in: Capsule())
                        }
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(isMac ? "macOS 恢复映像" : isWindows ? "Windows ARM64 安装映像" : "Linux 安装映像").font(.callout)
                                Text(draft.installerPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未挂载")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(draft.installerPath ?? "")
                            }
                            Spacer()
                            if !isMac && draft.installerPath != nil {
                                Button("弹出") { draft.installerPath = nil }.buttonStyle(PillButtonStyle())
                            }
                            Button("选择…") { if let path = FilePicker.image(mac: isMac) { draft.installerPath = path } }.buttonStyle(PillButtonStyle())
                        }
                        Text(isMac ? "选择本地完整 .ipsw。创建后点击“安装 macOS”，安装器将验证此 Mac 支持的硬件型号。" : isWindows ? "选择本地 Windows 11 ARM64 ISO。使用 UTM 的 QEMU 与 HVF 运行，Windows 安装完成并关机后，请在此弹出安装映像。" : "选择与宿主机同架构的 ISO。安装完成并关机后，在此弹出映像，再从虚拟磁盘启动。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    SectionPanel(title: "虚拟机文件", symbol: "shippingbox") {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(existing == nil ? "存放位置" : "文件包位置").font(.callout)
                                Text(existing.map { model.store.directory(for: $0).path } ?? (storageParent ?? model.store.rootURL).path)
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    .lineLimit(3).truncationMode(.middle)
                            }
                            Spacer()
                            if existing == nil {
                                Button("选择…") {
                                    if let path = FilePicker.folder(title: "选择虚拟机存放位置") { storageParent = URL(fileURLWithPath: path, isDirectory: true) }
                                }.buttonStyle(PillButtonStyle())
                            }
                        }
                        Text("配置、磁盘和固件保存在一个 .virtvm 文件包中。关机后可整体复制或移动，再用“打开虚拟机”添加。安装映像和共享文件夹仍引用原位置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if isWindows {
                        SectionPanel(title: "Windows on ARM", symbol: "pc") {
                            HStack {
                                Image(systemName: woaRuntime == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(woaRuntime == nil ? Color.orange : Color.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(woaRuntime == nil ? "应用内 WoA 运行组件缺失" : "WoA 运行时已内置 · UTM \(woaRuntime?.version ?? "")").font(.callout)
                                    Text(woaRuntime == nil ? "请重新安装完整版本的 Virt Manager。" : "QEMU、固件、TPM、SPICE 与图形组件均随 Virt Manager.app 提供；无需单独安装 UTM。")
                                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            woaFileRow("Guest Tools ISO", path: $woaDriverISO, extensions: ["iso"])
                            Text("UTM Guest Tools 0.1.275 已内置，默认随虚拟机挂载，无需下载。在 Windows 中运行光盘里的 utm-guest-tools.exe 安装网络、SPICE 代理和 GPU 驱动。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Toggle("TPM 2.0 与 Secure Boot", isOn: $woaTPM).toggleStyle(.switch)
                            Text("Windows 11 需要 TPM 与 Secure Boot；TPM 状态保存在虚拟机文件包的 TPM 目录。UEFI 固件类型在创建时确定，之后再切换 TPM 不会替换已有变量。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SectionPanel(title: "计算资源", symbol: "cpu") {
                        resourceRow("处理器", value: $draft.cpuCount, range: 1...maxCPUs, unit: "核").disabled(isLiveEditing)
                        resourceRow("内存", value: $draft.memoryGiB, range: 1...maxMemory, unit: "GB").disabled(isLiveEditing)
                        resourceRow("磁盘容量", value: $draft.diskGiB, range: 16...2048, unit: "GB").disabled(existing != nil || isLiveEditing)
                        Text(existing == nil ? "磁盘按需占用实际空间。macOS 通常至少需要 2 核与 4 GB 内存，具体要求由恢复映像确定。" : "基础版不支持调整现有磁盘容量。CPU 和内存需满足客户机系统要求。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SectionPanel(title: "显示与设备", symbol: "display") {
                        HStack {
                            Text("初始分辨率")
                            Spacer()
                            Picker("初始分辨率", selection: resolution) {
                                ForEach(resolutions) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }.labelsHidden().frame(width: 280)
                        }.disabled(isLiveEditing && !isWindows)
                        if isWindows {
                            Picker("显示刷新率", selection: $woaDisplayRefreshHz) {
                                Text("60 Hz（默认）").tag(60)
                                Text("120 Hz").tag(120)
                            }.pickerStyle(.menu).disabled(isLiveEditing)
                            Text(isLiveEditing ? "分辨率可由已连接的 SPICE 代理调整；刷新率和图形模式需关机后修改。" : "向 Windows 提供所选刷新率的显示时序，下次启动生效。实际帧率受客户机驱动、图形模式与宿主性能影响，不保证达到 60 或 120 fps。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if isWindows {
                            Picker("网络模式", selection: $woaNetworkMode) {
                                ForEach(WoANetworkMode.allCases) { mode in Text(mode.title).tag(mode) }
                            }.pickerStyle(.menu).disabled(isLiveEditing)
                            Text(woaNetworkMode.detail).font(.caption).foregroundStyle(.secondary)
                            Text("网络模式和端口规则需关机修改，下次启动生效。").font(.caption).foregroundStyle(.secondary)
                            if woaNetworkMode == .userPortForward {
                                TextField("一条规则一行，例如 tcp:127.0.0.1:2222-:22", text: $woaPortForwards, axis: .vertical)
                                    .lineLimit(2...4).textFieldStyle(.plain).padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .disabled(isLiveEditing)
                                Text("127.0.0.1 仅允许本机访问。旧格式 tcp::2222-:22 会监听所有宿主 IPv4 地址，可能向局域网暴露客户机服务。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if woaNetworkMode == .socket {
                                TextField("外部 Unix socket 的绝对路径", text: Binding(get: { woaSocketPath ?? "" }, set: { woaSocketPath = $0.isEmpty ? nil : $0 }))
                                    .textFieldStyle(.plain).padding(.horizontal, 15).padding(.vertical, 9)
                                    .background(.quaternary.opacity(0.45), in: Capsule()).disabled(isLiveEditing)
                            }
                        } else {
                            Toggle("NAT 共享网络", isOn: $draft.networkEnabled).toggleStyle(.switch).disabled(isLiveEditing)
                        }
                        Toggle("音频输出", isOn: $draft.audioEnabled).toggleStyle(.switch).disabled(isLiveEditing)
                        if isWindows {
                            Text("剪贴板同步与随窗口调整分辨率由 SPICE 代理提供，需要在 Windows 中安装 UTM Guest Tools（含 spice-vdagent）。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !isMac && !isWindows {
                            Toggle("剪贴板双向同步", isOn: $draft.clipboardEnabled).toggleStyle(.switch)
                            Text("需要客户机安装并运行 spice-vdagent。Debian / Ubuntu：sudo apt install spice-vdagent，安装后注销并重新登录桌面。开启后，主机与客户机可相互读取复制的内容。")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if draft.kind == .linux {
                            Toggle("GPU 3D 加速", isOn: .constant(false)).toggleStyle(.switch).disabled(true)
                            Text("不可用：Virtualization.framework 当前没有公开 Linux 3D 加速接口。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("显示可随窗口自动调整，具体取决于客户机驱动。Linux 使用 virtio 显示；macOS 使用 Apple 虚拟图形设备。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if isWindows {
                        SectionPanel(title: "图形加速", symbol: "gpu") {
                            Picker("GPU 驱动", selection: $woaGPU) {
                                ForEach(WoAGraphicsMode.allCases) { mode in
                                    Text(woaCapabilities.supports(mode) ? mode.title : "\(mode.title) · 不可用").tag(mode)
                                }
                            }.pickerStyle(.menu)
                            Text(woaGPUDescription).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let reason = woaCapabilities.unavailableReason(for: woaGPU) {
                                Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            }
                            Text("3D 为实验功能：需要在 Windows 中安装 UTM Guest Tools 的 viogpu3d 驱动；暂停 3D 虚拟机可能导致黑屏，且并非所有程序都兼容。兼容模式不提供 3D；已有 viogpu3d 驱动的客户机仍需单独验证显示兼容性。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                             DisclosureGroup("额外 QEMU 参数") {
                                TextField("例如 -device usb-host,vendorid=…", text: $woaExtraArguments).textFieldStyle(.roundedBorder)
                            }.font(.callout)
                        }
                    }
                    if isWindows {
                        SectionPanel(title: "USB 设备", symbol: "cable.connector") {
                            HStack {
                                Text("分配给此虚拟机").font(.callout)
                                Spacer()
                                Button("刷新") { woaUSBInventory.refresh() }.buttonStyle(PillButtonStyle())
                            }
                            ForEach(woaUSBInventory.devices) { device in
                                Toggle(isOn: Binding(get: { woaUSBAssignments.contains(where: { $0.matches(device) }) }, set: { selected in
                                    if selected { woaUSBAssignments.insert(device.selection) }
                                    else { woaUSBAssignments = Set(woaUSBAssignments.filter { !$0.matches(device) }) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                        Text(device.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.toggleStyle(.switch)
                            }
                            if woaUSBInventory.devices.isEmpty {
                                Text("未发现可分配的 USB 设备").font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("新插入设备默认连接到此虚拟机", isOn: $woaAutoConnectUSB).toggleStyle(.switch)
                            Text("启动后连接所选设备；自动连接仅处理运行期间新插入的设备。USB 集线器及键鼠不自动接管。设备被 macOS 占用时，连接错误会显示在管理窗口。多台虚拟机不能同时占用同一设备。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                        if !isMac && !isWindows {
                            SectionPanel(title: "Rosetta for Linux", symbol: "arrow.triangle.branch") {
                            Toggle("运行 x86_64 Linux 程序", isOn: $draft.rosettaEnabled)
                                .toggleStyle(.switch).disabled(!LinuxRosettaSupport.isSupported || installingRosetta)
                            Text(rosettaStatus).font(.caption).foregroundStyle(.secondary)
                            if LinuxRosettaSupport.isSupported && !LinuxRosettaSupport.isInstalled {
                                Button(installingRosetta ? "正在安装…" : "安装 Rosetta 支持…") {
                                    installingRosetta = true
                                    Task { @MainActor in
                                        do { try await LinuxRosettaSupport.install() }
                                        catch { errorMessage = error.localizedDescription }
                                        rosettaStatus = LinuxRosettaSupport.statusText
                                        installingRosetta = false
                                    }
                                }.buttonStyle(PillButtonStyle()).disabled(installingRosetta)
                            }
                            Text("需要 ARM64 Linux 客户机。开启后提供 rosetta 共享目录，还需在客户机内挂载并注册 binfmt；不会转换整个 x86 系统。")
                                .font(.caption).foregroundStyle(.secondary)
                            if draft.rosettaEnabled {
                                Text("sudo mkdir -p /mnt/rosetta\nsudo mount -t virtiofs rosetta /mnt/rosetta\n/mnt/rosetta/rosetta /path/to/x86_64-program")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        SectionPanel(title: "文件夹共享", symbol: "folder") {
                            HStack {
                                Text(draft.sharedDirectoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未共享文件夹")
                                    .font(.callout).lineLimit(1)
                                Spacer()
                                if draft.sharedDirectoryPath != nil {
                                    Button("移除") { draft.sharedDirectoryPath = nil }.buttonStyle(PillButtonStyle())
                                }
                                Button("选择…") { if let path = FilePicker.folder() { draft.sharedDirectoryPath = path } }.buttonStyle(PillButtonStyle())
                            }
                            if draft.sharedDirectoryPath != nil {
                                Toggle("只读访问", isOn: $draft.sharedDirectoryReadOnly).toggleStyle(.switch)
                                Text("客户机需要 virtiofs 驱动。挂载命令：sudo mount -t virtiofs share /mnt/share")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        } else if isWindows {
                            SectionPanel(title: "文件夹共享", symbol: "folder") {
                                Toggle("Windows 文件夹共享（未支持）", isOn: .constant(false))
                                    .toggleStyle(.switch).disabled(true)
                                Text("当前版本未实现 Windows 所需的 SPICE WebDAV 共享。已禁用文件夹共享，不会挂载宿主目录；安装 Guest Tools 不会启用此功能。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if let path = draft.sharedDirectoryPath ?? draft.woaConfiguration?.sharedDirectory?.path {
                                    Text("旧共享配置已保留但不生效：\(path)")
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                    }
                    if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
                }.padding(26)
            }
            Divider()
            HStack {
                Text("所有数据保存在这台 Mac 上").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(PillButtonStyle())
                Button(existing == nil ? "创建虚拟机" : "保存设置", action: save)
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(saving || installingRosetta || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(22)
        }
        .onAppear {
            isLiveEditing = existing.map { model.runtime(for: $0).isRunning || model.runtime(for: $0).isPaused } ?? false
            if let existing {
                draft = existing
                if let configuration = existing.resolvedWoAConfiguration(in: model.store.directory(for: existing)) {
                    draft.woaConfiguration = configuration
                }
            } else {
                draft.name = "Linux"
                draft.cpuCount = min(4, maxCPUs)
                draft.memoryGiB = min(4, maxMemory)
            }
            if let configuration = existing.map({ $0.resolvedWoAConfiguration(in: model.store.directory(for: $0)) }) ?? draft.woaConfiguration {
                woaGPU = configuration.graphicsMode
                woaDriverISO = (configuration.driverISO ?? woaRuntime?.guestToolsISO)?.path
                woaTPM = configuration.tpmEnabled
                woaDisplayRefreshHz = configuration.displayRefreshHz
                woaExtraArguments = configuration.extraArguments
                woaUSBAssignments = Set(configuration.usbAssignments)
                woaAutoConnectUSB = configuration.autoConnectNewUSBDevices
                woaNetworkMode = configuration.networkMode
                woaPortForwards = configuration.networkPortForwards.joined(separator: "\n")
                woaSocketPath = configuration.networkSocketPath?.path
            }
            woaRuntime = WoARuntimeBundle.locate()
            if woaDriverISO == nil { woaDriverISO = woaRuntime?.guestToolsISO.path }
            let bundle = woaRuntime
            Task {
                let capabilities = await Task.detached(priority: .utility) { WoABackend.capabilities(bundle: bundle) }.value
                woaCapabilities = capabilities
            }
            resolutions = DisplayResolutions.options(screen: NSScreen.screens.first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == NSNumber(value: CGMainDisplayID()) }) ?? NSScreen.main)
            if let option = resolutions.first(where: { $0.width == draft.displayWidth && $0.height == draft.displayHeight }) {
                selectedResolution = option.id
            } else {
                let id = "\(draft.displayWidth)x\(draft.displayHeight)"
                resolutions.append(DisplayResolution(id: id, title: "当前 · \(draft.displayWidth) × \(draft.displayHeight)", width: draft.displayWidth, height: draft.displayHeight))
                selectedResolution = id
            }
        }
    }
    private var resolution: Binding<String> {
        Binding(get: { selectedResolution }, set: { value in
            guard let option = resolutions.first(where: { $0.id == value }) else { return }
            selectedResolution = value
            draft.displayWidth = option.width
            draft.displayHeight = option.height
        })
    }
    private func systemChoice(_ title: String, subtitle: String, symbol: String, kind: VMGuestKind) -> some View {
        Button { draft.kind = kind; draft.name = title; draft.installerPath = nil; if kind == .macOS { draft.sharedDirectoryPath = nil; draft.clipboardEnabled = false; draft.rosettaEnabled = false; draft.diskGiB = max(64, draft.diskGiB) } else if kind == .windowsARM64 { draft.sharedDirectoryPath = nil; draft.clipboardEnabled = false; draft.rosettaEnabled = false; draft.diskGiB = max(64, draft.diskGiB); draft.memoryGiB = max(8, draft.memoryGiB); draft.cpuCount = max(4, draft.cpuCount); draft.audioEnabled = true } } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if draft.kind == kind { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }.padding(17).background(draft.kind == kind ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }.buttonStyle(.plain)
    }
    private func woaFileRow(_ title: String, path: Binding<String?>, extensions: [String]) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text(path.wrappedValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未选择")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if path.wrappedValue != nil {
                Button("移除") { path.wrappedValue = nil }.buttonStyle(PillButtonStyle())
            }
            Button("选择…") {
                if let selected = FilePicker.file(title: "选择\(title)", extensions: extensions) { path.wrappedValue = selected }
            }.buttonStyle(PillButtonStyle())
        }
    }
    private func resourceRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .frame(width: 66).padding(.horizontal, 12).padding(.vertical, 7).background(.quaternary.opacity(0.4), in: Capsule())
            Text(unit).foregroundStyle(.secondary).frame(width: 24)
            Stepper(title, value: value, in: range).labelsHidden()
        }.font(.callout)
    }
    private func save() {
        saving = true
        Task { @MainActor in
        do {
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...maxCPUs).contains(draft.cpuCount), (1...maxMemory).contains(draft.memoryGiB) else {
                throw AppFailure("CPU 或内存超出这台 Mac 支持的范围。")
            }
            guard (16...2048).contains(draft.diskGiB) else { throw AppFailure("磁盘容量请设为 16 至 2048 GB。") }
            if draft.kind == .windowsARM64 {
                guard draft.cpuCount >= 2 else { throw AppFailure("Windows 11 ARM64 至少需要 2 个处理器核心。") }
                guard woaRuntime != nil else { throw AppFailure("本应用没有内置 WoA 运行组件，请重新安装完整版本。") }
                guard woaCapabilities.supports(woaGPU) else { throw AppFailure(woaCapabilities.unavailableReason(for: woaGPU) ?? "所选 GPU 模式不可用。") }
                var woaConfiguration = existing.flatMap { $0.resolvedWoAConfiguration(in: model.store.directory(for: $0)) } ?? WoAConfiguration()
                woaConfiguration.name = draft.name
                woaConfiguration.cpuCount = draft.cpuCount
                woaConfiguration.memoryGiB = draft.memoryGiB
                woaConfiguration.installerISO = draft.installerPath.map(URL.init(fileURLWithPath:))
                woaConfiguration.displayWidth = draft.displayWidth
                woaConfiguration.displayHeight = draft.displayHeight
                woaConfiguration.displayRefreshHz = woaDisplayRefreshHz
                woaConfiguration.networkEnabled = woaNetworkMode != .disconnected
                woaConfiguration.networkMode = woaNetworkMode
                woaConfiguration.networkPortForwards = woaPortForwards.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if woaNetworkMode == .socket, let path = woaSocketPath, !path.hasPrefix("/") {
                    throw AppFailure("Socket 网络必须使用绝对路径。")
                }
                woaConfiguration.networkSocketPath = woaSocketPath.map { URL(fileURLWithPath: $0) }
                // Preserve inactive legacy sharing fields verbatim; the Windows UI cannot change them.
                woaConfiguration.audioEnabled = draft.audioEnabled
                woaConfiguration.tpmEnabled = woaTPM
                woaConfiguration.graphicsMode = woaGPU
                woaConfiguration.driverISO = woaDriverISO.map(URL.init(fileURLWithPath:))
                woaConfiguration.extraArguments = woaExtraArguments
                woaConfiguration.usbAssignments = Array(woaUSBAssignments)
                woaConfiguration.autoConnectNewUSBDevices = woaAutoConnectUSB
                try woaConfiguration.validate()
                draft.networkEnabled = woaConfiguration.networkEnabled
                draft.woaConfiguration = woaConfiguration
            }
            if isLiveEditing {
                guard let existing else { throw AppFailure("找不到正在运行的虚拟机。") }
                guard woaGPU == (existing.resolvedWoAConfiguration(in: model.store.directory(for: existing))?.graphicsMode ?? .software),
                      woaTPM == (existing.resolvedWoAConfiguration(in: model.store.directory(for: existing))?.tpmEnabled ?? woaTPM),
                      woaExtraArguments == (existing.resolvedWoAConfiguration(in: model.store.directory(for: existing))?.extraArguments ?? woaExtraArguments),
                      draft.audioEnabled == existing.audioEnabled else { throw AppFailure("图形模式、TPM、启动参数和音频需关机后修改。") }
                if isWindows {
                    if let old = existing.woaConfiguration {
                        guard woaNetworkMode == old.networkMode,
                              draft.woaConfiguration?.networkPortForwards == old.networkPortForwards,
                              draft.woaConfiguration?.networkSocketPath == old.networkSocketPath else {
                            throw AppFailure("网络模式和端口规则需关机后修改。")
                        }
                    }
                    guard let old = existing.resolvedWoAConfiguration(in: model.store.directory(for: existing)),
                          woaGPU == old.graphicsMode, woaTPM == old.tpmEnabled, woaExtraArguments == old.extraArguments,
                          woaDriverISO == old.driverISO?.path || woaDriverISO == woaRuntime?.guestToolsISO.path else {
                        throw AppFailure("图形模式、TPM、启动参数和 Guest Tools 映像需关机后修改。")
                    }
                }
                try await model.runtime(for: existing).updateSettingsWhileRunning(draft)
                model.revision += 1
                dismiss()
                return
            }
            if existing == nil {
                guard draft.installerPath != nil else { throw AppFailure("请先选择安装映像。") }
                try model.store.create(draft, parentDirectory: storageParent)
                model.selectedID = draft.id
            } else { try model.save(draft) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        saving = false
        }
    }
}
