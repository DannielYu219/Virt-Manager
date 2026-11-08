import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(prominent ? AnyShapeStyle(Color.accentColor.opacity(configuration.isPressed ? 0.65 : 1)) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SectionPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            content
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

enum FilePicker {
    @MainActor static func image(mac: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.title = mac ? "选择 macOS 恢复映像" : "选择 Linux 或 Windows ARM64 安装映像"
        panel.allowedContentTypes = mac ? [UTType(filenameExtension: "ipsw") ?? .data] : [UTType(filenameExtension: "iso") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    @MainActor static func folder(title: String = "选择共享文件夹") -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    @MainActor static func file(title: String, extensions: [String]) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    @MainActor static func virtualMachine() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "打开虚拟机"
        panel.allowedContentTypes = [UTType(exportedAs: "com.dannielyu.virtmanager.vm", conformingTo: .package)]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
