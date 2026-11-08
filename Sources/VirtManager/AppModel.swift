import SwiftUI
import AppKit
import Combine

@MainActor final class AppModel: ObservableObject {
    let store = VMStore(rootURL: CommandLine.arguments.contains(where: { ["--self-check", "--display-self-check", "--woa-probe"].contains($0) })
        ? FileManager.default.temporaryDirectory.appendingPathComponent("VirtManager-ui-check-\(UUID().uuidString)", isDirectory: true)
        : nil)
    @Published var selectedID: UUID?
    @Published var revision = 0
    @Published var errorMessage: String?
    private var sessions: [UUID: VMRuntime] = [:]
    private var displays: [UUID: VMDisplayController] = [:]
    private var displayMachines: [UUID: ObjectIdentifier] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]

    func runtime(for record: VMRecord) -> VMRuntime {
        if let runtime = sessions[record.id] { return runtime }
        let runtime = VMRuntime(record: record, directory: store.directory(for: record))
        sessions[record.id] = runtime
        runtime.onRecordChange = { [weak self] _ in self?.store.reload() }
        subscriptions[record.id] = runtime.objectWillChange.sink { [weak self, weak runtime] _ in
            DispatchQueue.main.async {
                guard let self, let runtime, self.sessions[record.id] === runtime else { return }
                self.objectWillChange.send()
                if runtime.displayIdentity == nil || runtime.isStopped {
                    self.displays[record.id]?.close()
                    self.displays[record.id] = nil
                    self.displayMachines[record.id] = nil
                } else if runtime.displayIdentity != nil,
                          self.displayMachines[record.id] != runtime.displayIdentity {
                    self.showDisplay(for: record)
                }
            }
        }
        return runtime
    }
    func showDisplay(for record: VMRecord) {
        let runtime = runtime(for: record)
        guard let identity = runtime.displayIdentity else { return }
        if let display = displays[record.id], displayMachines[record.id] == identity {
            display.show()
            return
        }
        displays[record.id]?.close()
        let display: VMDisplayController
        if let view = runtime.woa?.displayView {
            display = VMDisplayController(view: view, title: record.name, onClose: {})
        } else if let machine = runtime.machine {
            display = VMDisplayController(machine: machine, title: record.name, onClose: {})
        } else { return }
        displays[record.id] = display
        displayMachines[record.id] = identity
        display.show()
    }
    func save(_ record: VMRecord) throws {
        guard runtime(for: record).canEdit else { throw AppFailure("请先关闭虚拟机，再修改配置。") }
        try store.update(record)
        displays[record.id]?.close()
        displays[record.id] = nil
        displayMachines[record.id] = nil
        sessions[record.id] = nil
        subscriptions[record.id] = nil
        revision += 1
    }
    func remove(_ record: VMRecord) {
        do {
            guard runtime(for: record).canEdit else { throw AppFailure("请先关闭虚拟机，再移到废纸篓。") }
            try store.remove(record)
            displays[record.id]?.close()
            displays[record.id] = nil
            displayMachines[record.id] = nil
            sessions[record.id] = nil
            subscriptions[record.id] = nil
            if selectedID == record.id { selectedID = store.machines.first?.id }
        } catch { errorMessage = error.localizedDescription }
    }
    func choosePackage() {
        if let url = FilePicker.virtualMachine() { openPackage(url) }
    }
    func openPackage(_ url: URL) {
        do {
            let incoming = try VMPackage.read(from: url)
            if let runtime = sessions[incoming.id], !runtime.canEdit {
                guard store.directory(for: incoming).standardizedFileURL == url.standardizedFileURL else {
                    throw AppFailure("此虚拟机正在运行，请先关机再打开其他位置的副本。")
                }
                selectedID = incoming.id
                return
            }
            let record = try store.importPackage(at: url)
            displays[record.id]?.close()
            displays[record.id] = nil
            displayMachines[record.id] = nil
            subscriptions[record.id] = nil
            sessions[record.id] = nil
            selectedID = record.id
            revision += 1
        } catch { errorMessage = error.localizedDescription }
    }
    var hasActiveMachines: Bool { sessions.values.contains { !$0.canEdit } }
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel? {
        didSet {
            guard let model else { return }
            let pending = pendingURLs
            pendingURLs.removeAll()
            for url in pending { model.openPackage(url) }
        }
    }
    private static var pendingURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model = Self.model {
            for url in urls { model.openPackage(url) }
        } else { Self.pendingURLs.append(contentsOf: urls) }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--woa-probe") && !CommandLine.arguments.contains("window") {
            NSApp.setActivationPolicy(.prohibited)
        }
        if CommandLine.arguments.contains("--display-self-check") {
            NSApp.setActivationPolicy(.prohibited)
            do { try DisplaySelfCheck.run(); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-check") {
            do { try SelfCheck.run(); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--woa-probe") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            Task { @MainActor in exit(await WoAProbe.run(arguments: rest)) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.model?.hasActiveMachines == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "仍有虚拟机在运行"
        alert.informativeText = "请先在虚拟机中关机，或返回管理界面关闭虚拟机，再退出应用。"
        alert.addButton(withTitle: "返回虚拟机")
        alert.runModal()
        return .terminateCancel
    }
}

@main enum VirtManagerEntry {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--woa-probe"),
           !CommandLine.arguments.contains("window") {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            let arguments = Array(CommandLine.arguments.dropFirst(index + 1))
            Task { @MainActor in exit(await WoAProbe.run(arguments: arguments)) }
            application.run()
            return
        }
        VirtManagerApp.main()
    }
}

struct VirtManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Virt Manager") {
            LibraryView(model: model, store: model.store)
                .background(ManagerWindowPolicy())
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear { AppDelegate.model = model }
        }
        .defaultSize(width: 1180, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("打开虚拟机…") { model.choosePackage() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .windowArrangement) {
                Button("显示管理窗口") {
                    if let manager = NSApp.windows.first(where: { $0.title == "Virt Manager" && $0.canBecomeMain }) {
                        if manager.isMiniaturized { manager.deminiaturize(nil) }
                        manager.makeKeyAndOrderFront(nil)
                    }
                }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("切换沉浸模式") { VMDisplayController.focused?.toggleImmersive() }
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                Button("退出沉浸模式") { VMDisplayController.focused?.exitImmersive() }
                    .keyboardShortcut("q", modifiers: [.command, .option, .shift])
            }
        }
    }
}

/// The library remains an ordinary window while guest windows create native fullscreen Spaces.
private struct ManagerWindowPolicy: NSViewRepresentable {
    final class PolicyView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.collectionBehavior = [.fullScreenNone]
            window?.tabbingMode = .disallowed
        }
    }
    func makeNSView(context: Context) -> NSView { PolicyView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
