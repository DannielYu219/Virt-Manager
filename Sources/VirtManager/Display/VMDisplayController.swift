import AppKit
import SwiftUI
import Virtualization

/// Same unconstrained, normal-level window as Project-Virt/FullscreenController.swift.
private final class GuestDisplayWindow: NSWindow {
    var immersive = false
    var onToggleImmersive: (() -> Void)?
    // AppKit can recreate the green button when styleMask/toolbar changes. Keep
    // its default responder-chain actions on the same path as our explicit target.
    override func zoom(_ sender: Any?) { onToggleImmersive?() }
    override func toggleFullScreen(_ sender: Any?) { onToggleImmersive?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        immersive ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Restores the original single borderless NSWindow display path. No fullscreen
/// host, auxiliary window, safe-area constraints, or scaling workaround is used.
@MainActor
final class VMDisplayController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static weak var focused: VMDisplayController?
    private static weak var presentationOwner: VMDisplayController?
    private static let recoveryHotKey = ImmersiveExitHotKey()
    private static var recoveryInstalled = false

    private let window: GuestDisplayWindow
    private let vmView: NSView
    private let onClose: () -> Void
    private var savedFrame: NSRect?
    private var savedPresentation: NSApplication.PresentationOptions?
    private var observers: [NSObjectProtocol] = []
    private var immersive = false
    private var isChangingMode = false
    private var isShown = false
    private var cursorHidden = false
    private static let windowedStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    private static let minimumContentSize = NSSize(width: 640, height: 400)

    convenience init(machine: VZVirtualMachine, title: String, onClose: @escaping () -> Void) {
        let view = VZVirtualMachineView(frame: .zero)
        view.virtualMachine = machine
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = true
        self.init(view: view, title: title, onClose: onClose)
    }

    init(view: NSView, title: String, onClose: @escaping () -> Void) {
        vmView = view
        self.onClose = onClose
        window = GuestDisplayWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 720),
                                    styleMask: Self.windowedStyle,
                                    backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.backgroundColor = .black
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.contentMinSize = Self.minimumContentSize
        window.onToggleImmersive = { [weak self] in self?.toggleImmersive() }
        vmView.translatesAutoresizingMaskIntoConstraints = true
        vmView.autoresizingMask = [.width, .height]
        // Install exactly once. AppKit owns its root content view's frame; do not
        // overwrite it with an intermediate contentLayoutRect while the window's
        // titlebar and toolbar are being rebuilt.
        window.contentView = vmView
        let toolbar = NSToolbar(identifier: "VMDisplayToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .expanded
        window.toolbar = toolbar
        toolbar.isVisible = true
        // Install essential items explicitly; visibility/default-item restoration
        // must not depend on AppKit's previously saved toolbar state.
        for (index, identifier) in toolbarDefaultItemIdentifiers(toolbar).enumerated() {
            if !toolbar.items.contains(where: { $0.itemIdentifier == identifier }) {
                toolbar.insertItem(withItemIdentifier: identifier, at: min(index, toolbar.items.count))
            }
        }
        // One entry: route the green window control through the same immersive path.
        bindZoomButton()
        if let display = vmView as? WoADisplayView {
            display.client.onClipboardStatus = { [weak self] status in
                guard let item = self?.window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "clipboard-status" }),
                      let label = item.view as? NSTextField else { return }
                label.stringValue = status
                label.toolTip = status
            }
        }
        window.center()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPresentation() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPresentation() }
        })
    }

    func show() {
        isShown = true
        if !immersive { window.toolbar?.isVisible = true }
        bindZoomButton()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vmView)
        NSApp.activate(ignoringOtherApps: true)
        Self.focused = self
        syncPresentation()
    }

    @objc private func toggleFromWindowControl() { toggleImmersive() }

    private func bindZoomButton() {
        guard let button = window.standardWindowButton(.zoomButton) else { return }
        button.target = self
        button.action = #selector(toggleFromWindowControl)
    }

    func toggleImmersive() {
        guard !isChangingMode else { return }
        if immersive { exitImmersive(); return }
        guard isShown, let screen = window.screen ?? NSScreen.main else { return }
        if !Self.recoveryInstalled {
            do {
                try Self.recoveryHotKey.register {
                    (Self.presentationOwner ?? Self.focused)?.exitImmersive()
                }
                Self.recoveryInstalled = true
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }
        }
        isChangingMode = true
        defer { isChangingMode = false; syncPresentation() }
        // Snapshot before toolbar/style changes: both may synchronously deliver
        // resize, screen and key-window callbacks while AppKit rebuilds chrome.
        savedFrame = usableWindowedFrame(window.frame)
        immersive = true
        window.immersive = true
        window.toolbar?.isVisible = false
        window.styleMask = [.borderless]
        window.hasShadow = false
        window.setFrame(screen.frame, display: true)
        (vmView as? WoADisplayView)?.setFullscreenFill(true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vmView)
    }

    func exitImmersive() {
        guard immersive, !isChangingMode else { return }
        isChangingMode = true
        defer { isChangingMode = false; syncPresentation() }
        immersive = false
        (vmView as? WoADisplayView)?.setPointerCaptured(false)
        restorePresentation()
        window.immersive = false
        window.styleMask = Self.windowedStyle
        window.hasShadow = true
        window.toolbar?.isVisible = true
        // Restore the outer frame only after all window chrome is back. Leave
        // the direct content view's sizing to NSWindow, including toolbar space.
        window.setFrame(usableWindowedFrame(savedFrame), display: true)
        savedFrame = nil
        window.contentView?.layoutSubtreeIfNeeded()
        bindZoomButton()
        // AppKit may finish replacing titlebar controls on the next main turn.
        // This callback changes no geometry, focus or mode and is safe to repeat.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.immersive, !self.isChangingMode else { return }
            self.bindZoomButton()
        }
        (vmView as? WoADisplayView)?.setFullscreenFill(false)
        if isShown && NSApp.isActive && window.isKeyWindow {
            window.makeFirstResponder(vmView)
        }
    }

    private func usableWindowedFrame(_ candidate: NSRect?) -> NSRect {
        let fallback = window.frameRect(forContentRect: NSRect(x: 100, y: 100, width: 1100, height: 720))
        guard let candidate, candidate.origin.x.isFinite, candidate.origin.y.isFinite,
              candidate.width.isFinite, candidate.height.isFinite else { return fallback }
        let minimum = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize),
                                         styleMask: Self.windowedStyle).size
        guard candidate.width >= minimum.width, candidate.height >= minimum.height else { return fallback }
        return candidate
    }

    private func syncPresentation() {
        guard !isChangingMode else { return }
        let active = isShown && NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace
        (vmView as? WoADisplayView)?.setWindowActive(active)
        (vmView as? WoADisplayView)?.setPointerCaptured(immersive && active)
        if immersive && active {
            if Self.presentationOwner !== self {
                Self.presentationOwner?.restorePresentation()
                savedPresentation = NSApp.presentationOptions
                Self.presentationOwner = self
            }
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        } else { restorePresentation() }
        if vmView is VZVirtualMachineView {
            if active && !cursorHidden { NSCursor.hide(); cursorHidden = true }
            else if !active && cursorHidden { NSCursor.unhide(); cursorHidden = false }
        }
    }

    private func restorePresentation() {
        guard Self.presentationOwner === self else { return }
        NSApp.presentationOptions = savedPresentation ?? []
        savedPresentation = nil
        Self.presentationOwner = nil
    }

    func close() {
        guard isShown else { return }
        isShown = false
        exitImmersive()
        syncPresentation()
        if Self.focused === self { Self.focused = nil }
        window.orderOut(nil)
        onClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func windowDidBecomeKey(_ notification: Notification) {
        Self.focused = self
        if !immersive && !isChangingMode { bindZoomButton() }
        syncPresentation()
    }
    func windowDidResignKey(_ notification: Notification) {
        if Self.focused === self { Self.focused = nil }
        syncPresentation()
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard !isChangingMode else { return }
        if immersive, let screen = window.screen, window.frame != screen.frame {
            isChangingMode = true
            window.setFrame(screen.frame, display: true)
            isChangingMode = false
        }
        syncPresentation()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = []
        if vmView is WoADisplayView { items.append(NSToolbarItem.Identifier("clipboard-status")) }
        items += [.flexibleSpace, NSToolbarItem.Identifier("immersive")]
        return items
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier.rawValue == "clipboard-status", let display = vmView as? WoADisplayView {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "剪贴板连接"
            let label = NSTextField(labelWithString: display.client.clipboardStatus)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
            label.lineBreakMode = .byTruncatingTail
            item.view = label
            return item
        }
        guard identifier.rawValue == "immersive" else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "沉浸模式"
        item.view = NSHostingView(rootView: Button { [weak self] in self?.toggleImmersive() } label: {
            Label("沉浸模式", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }.buttonStyle(.plain).help("进入沉浸 ⌘⌥Return · 退出 ⌘⌥⇧Q"))
        item.view?.frame.size = NSSize(width: 128, height: 32)
        return item
    }

    /// Geometry evidence for the no-guest fullscreen regression check.
    func verifyImmersiveGeometry() throws -> [String: String] {
        guard immersive, let screen = window.screen,
              window.styleMask == [.borderless], window.frame == screen.frame,
              vmView.frame == NSRect(origin: .zero, size: screen.frame.size),
              window.contentView === vmView else { throw AppFailure("Original fullscreen window geometry was not restored") }
        return ["window": NSStringFromRect(window.frame), "screen": NSStringFromRect(screen.frame),
                "guestView": NSStringFromRect(vmView.frame), "content": "direct guest view; no wrapper/auxiliary window"]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if cursorHidden { NSCursor.unhide() }
        if let savedPresentation { MainActor.assumeIsolated { NSApp.presentationOptions = savedPresentation } }
    }
}
