import SwiftUI
import AppKit

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: VMStore
    @State private var creating = false
    @State private var deleting: VMRecord?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Virt Manager").font(.headline)
                        Text("你的虚拟工作空间").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 20).padding(.top, 32).padding(.bottom, 28)
                HStack {
                    Text("虚拟机").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.machines.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }.padding(.horizontal, 22)
                List(selection: $model.selectedID) {
                    ForEach(store.machines) { record in
                        HStack(spacing: 12) {
Image(systemName: record.kind == .macOS ? "apple.logo" : record.kind == .windowsARM64 ? "windows.logo" : "terminal")
                                .font(.system(size: 19, weight: .medium)).frame(width: 32, height: 38)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(record.cpuCount) 核 · \(record.memoryGiB) GB").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).tag(record.id)
                        .contextMenu {
                            Button("启动") { model.runtime(for: record).start() }.disabled(!model.runtime(for: record).canEdit)
                            Button("打开显示窗口") { model.showDisplay(for: record) }.disabled(model.runtime(for: record).displayIdentity == nil)
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: record)]) }
                            Button("移到废纸篓…", role: .destructive) { deleting = record }
                                .disabled(!model.runtime(for: record).canEdit)
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                VStack(spacing: 8) {
                    Button { creating = true } label: {
                        Label("新建虚拟机", systemImage: "plus").frame(maxWidth: .infinity)
                    }.buttonStyle(PillButtonStyle())
                    Button { model.choosePackage() } label: {
                        Label("打开虚拟机…", systemImage: "folder").frame(maxWidth: .infinity)
                    }.buttonStyle(PillButtonStyle())
                }.padding(16)
                Label("Virtualization · QEMU/HVF", systemImage: "cpu").font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.bottom, 16)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 340)
        } detail: {
            if let record = store.machines.first(where: { $0.id == model.selectedID }) {
                MachineDetailView(model: model, runtime: model.runtime(for: record), record: record)
                    .id("\(record.id)-\(model.revision)")
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 60, weight: .ultraLight)).foregroundStyle(.secondary)
                    VStack(spacing: 10) {
                        Text("另一台电脑，同一个 Mac。").font(.system(size: 29, weight: .medium))
                        Text("创建 Linux、macOS 或 Windows ARM64 虚拟机，留出一片独立的工作空间。")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Button { creating = true } label: { Label("创建第一台虚拟机", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle(prominent: true)).padding(.top, 6)
                    Text("使用本机架构的安装映像 · 数据保存在本地").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .sheet(isPresented: $creating) { MachineEditor(model: model, existing: nil) }
        .alert("移到废纸篓？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("移到废纸篓", role: .destructive) { if let record = deleting { model.remove(record) }; deleting = nil }
        } message: { Text("虚拟机配置和磁盘将一起移到废纸篓。") }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil || store.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; store.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil; store.errorMessage = nil }
        } message: { Text(model.errorMessage ?? store.errorMessage ?? "") }
    }
}

struct MachineDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var runtime: VMRuntime
    let record: VMRecord
    @State private var editing = false
    @State private var forceConfirm = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.kind == .macOS ? "MACOS 虚拟机" : record.kind == .windowsARM64 ? "WINDOWS ARM64 虚拟机" : "LINUX 虚拟机")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                        Text(record.name).font(.system(size: 34, weight: .medium)).textSelection(.enabled)
                        HStack(spacing: 7) {
                            Circle().fill(runtime.isRunning ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                            Text(runtime.status).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { editing = true } label: { Label("设置", systemImage: "slider.horizontal.3") }
                        .buttonStyle(PillButtonStyle()).disabled(!runtime.canEdit)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
                    VStack(spacing: 17) {
                        Image(systemName: record.kind == .macOS ? "apple.logo" : record.kind == .windowsARM64 ? "windows.logo" : "terminal")
                            .font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.secondary)
                        Text(runtime.isRunning ? "虚拟机正在运行" : runtime.isPaused ? "工作空间已暂停" : "准备好，进入你的工作空间。")
                            .font(.system(size: 17, weight: .medium))
                        HStack(spacing: 10) {
                            if runtime.isRunning || runtime.isPaused {
                                Button { model.showDisplay(for: record) } label: { Label("打开显示窗口", systemImage: "macwindow") }
                                    .buttonStyle(PillButtonStyle(prominent: true))
                                if runtime.isPaused {
                                    Button("继续") { runtime.resume() }.buttonStyle(PillButtonStyle())
                                } else {
                                    Button { runtime.pause() } label: { Image(systemName: "pause.fill").fontWeight(.bold) }.buttonStyle(PillButtonStyle())
                                        .disabled(record.woaConfiguration?.graphicsMode.usesGL == true)
                                        .help(record.woaConfiguration?.graphicsMode.usesGL == true ? "3D 加速的 Windows 虚拟机暂停后可能黑屏或冻结，已禁用暂停" : "暂停")
                                    Button { runtime.requestStop() } label: { Image(systemName: "power").fontWeight(.bold) }.buttonStyle(PillButtonStyle()).help("向客户机请求关机")
                                }
                            } else if !runtime.isBusy {
                                if record.kind != .macOS || record.macInstalled {
                                    Button { runtime.start() } label: { Label("启动虚拟机", systemImage: "play.fill") }
                                        .buttonStyle(PillButtonStyle(prominent: true))
                                }
                                if record.kind == .macOS && !record.macInstalled {
                                    Button("安装 macOS") { runtime.installMacOS() }.buttonStyle(PillButtonStyle())
                                }
                            } else { ProgressView().controlSize(.small); Text(runtime.status).font(.caption).foregroundStyle(.secondary) }
                            Button { forceConfirm = true } label: {
                                Label("强制停止", systemImage: "stop.circle.fill")
                            }
                            .buttonStyle(PillButtonStyle())
                            .foregroundStyle(.red)
                            .disabled(runtime.canEdit)
                            .help("立即强制停止此虚拟机；未保存的数据可能丢失")
                        }
                        if runtime.isBusy {
                            ProgressView(value: runtime.progress).frame(width: 220)
                        }
                    }.padding(30)
                }.frame(height: 292)
                if let message = runtime.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 16) {
                    SectionPanel(title: "计算资源", symbol: "cpu") {
                        infoRow("处理器", "\(record.cpuCount) 核")
                        infoRow("内存", "\(record.memoryGiB) GB")
                        infoRow("磁盘容量", "\(record.diskGiB) GB")
                    }
                    SectionPanel(title: "设备与连接", symbol: "display") {
                        infoRow("显示", "\(record.displayWidth) × \(record.displayHeight)")
                        infoRow("网络", record.networkEnabled ? "NAT 共享网络" : "已断开")
                        if let woa = record.woaConfiguration, record.kind == .windowsARM64 {
                            infoRow("图形", woa.graphicsMode.title)
                            infoRow("TPM", woa.tpmEnabled ? "TPM 2.0 · Secure Boot" : "关闭")
                        } else {
                            infoRow("共享目录", record.sharedDirectoryPath == nil ? "未配置" : "已配置")
                        }
                    }
                }
                SectionPanel(title: "独立全屏工作空间", symbol: "arrow.up.left.and.arrow.down.right") {
                    Text("在虚拟机窗口中点击绿色全屏按钮或使用 ⌘⌥Return。macOS 会为这台虚拟机创建独立的全屏 Space，管理窗口仍留在原桌面。可同时启动多台虚拟机，每台拥有独立窗口。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                    HStack { Label("⌘⌥⇧Q 返回普通窗口", systemImage: "escape"); Spacer(); Text("保留系统应用切换") }
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("在访达中显示文件") { NSWorkspace.shared.activateFileViewerSelecting([model.store.directory(for: record)]) }.buttonStyle(.plain)
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(36).frame(maxWidth: 1020)
                .frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $editing) { MachineEditor(model: model, existing: record) }
        .alert("强制停止虚拟机？", isPresented: $forceConfirm) {
            Button("取消", role: .cancel) {}
            Button("强制停止", role: .destructive) { runtime.forceStop() }
        } message: { Text("未保存的客户机数据可能丢失。建议先在客户机系统中正常关机。") }
    }
    func infoRow(_ key: String, _ value: String) -> some View {
        HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12))
    }
}
