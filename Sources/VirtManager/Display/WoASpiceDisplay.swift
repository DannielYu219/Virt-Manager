import AppKit
import Carbon.HIToolbox
import CSpiceBridge
import IOSurface
import Metal
import MetalKit

/// Connects to the SPICE server through the UTM-compatible frameworks bundled in this app.
/// All SPICE traffic runs on the bridge's private thread; every callback is hopped onto the main queue.
@MainActor
final class WoASpiceClient {
    private(set) var session: OpaquePointer?
    private var retained: Unmanaged<WoASpiceClient>?
    private(set) var isConnected = false
    private(set) var agentConnected = false
    private(set) var pointerIsAbsolute = true
    private var agentAnnounced = false
    private var hostClipboardAnnounced = false
    private var hostClipboardText: String?
    private var frameTimer: Timer?
    private var presentationHz = 60

    var onConnectionChange: ((Bool) -> Void)?
    var onSurface: ((CGSize) -> Void)?
    var onFrame: (() -> Void)?
    var onGLFrame: ((WoAGLFrame, @escaping () -> Void) -> Void)?
    private(set) var usingGL = false
    weak var activeMetalDisplay: WoAMetalDisplayView?
    var fallbackImage: CGImage?
    var clipboardIntegrationEnabled = true
    private(set) var clipboardCapability = false
    private(set) var clipboardStatus = "等待 SPICE agent 连接"
    var onClipboardStatus: ((String) -> Void)?

    private func reportClipboard(_ status: String) {
        clipboardStatus = status
        onClipboardStatus?(status)
    }
    var onCursor: ((NSCursor?) -> Void)?
    var onAgentChange: ((Bool) -> Void)?
    var onPointerModeChanged: ((Bool) -> Void)?
    var onGuestClipboard: ((String) -> Void)?

    func open(socket: URL, frameworks: URL) throws {
        guard session == nil else { return }
        let box = Unmanaged.passRetained(self)
        var callbacks = SBCallbacks()
        callbacks.context = box.toOpaque()
        callbacks.connection = { context, connected in
            guard let context else { return }
            let client = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { client.connectionChanged(connected != 0) } }
        }
        callbacks.surface = { context, width, height in
            guard let context else { return }
            let client = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard client.session != nil else { return }
                client.usingGL = false
                client.onSurface?(CGSize(width: Int(width), height: Int(height)))
            } }
        }
        // Frame presentation is coalesced at 60 Hz, not scheduled for every damage rectangle.
        callbacks.cursor = { context, width, height, hotX, hotY, rgba in
            guard let context else { return }
            let client = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            var pixels: Data?
            if let rgba, width > 0, height > 0 { pixels = Data(bytes: rgba, count: Int(width) * Int(height) * 4) }
            let size = (Int(width), Int(height), Int(hotX), Int(hotY))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let cursor = pixels.flatMap { WoASpiceClient.makeCursor(rgba: $0, width: size.0, height: size.1, hotX: size.2, hotY: size.3) }
                    client.onCursor?(cursor)
                }
            }
        }
        callbacks.mouse_mode = { context, client in
            guard let context else { return }
            let owner = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            let absolute = client != 0
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.pointerModeChanged(absolute) } }
        }
        callbacks.clipboard_text = { context, text, length in
            guard let context, length >= 0, length <= 16 * 1024 * 1024, text != nil || length == 0 else { return }
            let client = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            let string = String(decoding: UnsafeRawBufferPointer(start: text, count: Int(length)), as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { client.receivedGuestClipboard(string) } }
        }
        callbacks.agent = { context, connected in
            guard let context else { return }
            let client = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { client.agentChanged(connected != 0) } }
        }
        callbacks.clipboard_status = { context, status in
            guard let context else { return }
            let client = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                guard client.session != nil else { return }
                if status <= 2 { client.clipboardCapability = status == 2 }
                let messages = ["Agent 未连接：检查 Windows spice-agent 服务", "Agent 已连接，等待剪贴板能力协商", "剪贴板通道就绪", "已向 Windows 宣告宿主文本", "Windows 已请求宿主文本", "已收到 Windows 文本"]
                if (0..<messages.count).contains(Int(status)) { client.reportClipboard(messages[Int(status)]) }
            }
        }
        callbacks.gl_surface = { context, surface, token, width, height, stride, format, top in
            guard let context, let surface, let token else { return }
            let client = Unmanaged<WoASpiceClient>.fromOpaque(context).takeUnretainedValue()
            let object = Unmanaged<IOSurfaceRef>.fromOpaque(surface).takeUnretainedValue()
            let frame = WoAGLFrame(surface: object, token: token, width: Int(width), height: Int(height), bytesPerRow: stride, pixelFormat: format, y0top: top != 0)
            DispatchQueue.main.async {
                guard client.session != nil, let handler = client.onGLFrame else { sb_gl_surface_complete(token); return }
                handler(frame) { sb_gl_surface_complete(token) }
            }
        }
        var error = [CChar](repeating: 0, count: 512)
        guard let opened = sb_open(frameworks.path, socket.path, callbacks, &error, Int32(error.count)) else {
            box.release()
            throw WoAError.qemuUnavailable("无法启动 SPICE 显示客户端：\(String(cString: error))")
        }
        retained = box
        session = opened
        configurePresentation(hz: presentationHz)
    }

    func configurePresentation(hz: Int) {
        presentationHz = hz == 120 ? 120 : 60
        frameTimer?.invalidate()
        frameTimer = nil
        guard session != nil else { return }
        let interval = 1.0 / Double(presentationHz)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.usingGL != true { self?.onFrame?() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    func close() {
        guard let session else { return }
        self.session = nil
        frameTimer?.invalidate()
        frameTimer = nil
        // Teardown may wait for the renderer; never wait on the management/UI thread.
        let owner = retained
        retained = nil
        let address = UInt(bitPattern: session)
        DispatchQueue.global(qos: .userInitiated).async {
            sb_close(OpaquePointer(bitPattern: address))
            owner?.release()
        }
        isConnected = false
        usingGL = false
        activeMetalDisplay?.invalidatePendingFrames()
        activeMetalDisplay = nil
        fallbackImage = nil
        pointerIsAbsolute = true
        agentConnected = false
        agentAnnounced = false
        hostClipboardAnnounced = false
        hostClipboardText = nil
    }

    func pointerModeChanged(_ absolute: Bool) {
        guard session != nil, pointerIsAbsolute != absolute else { return }
        pointerIsAbsolute = absolute
        onPointerModeChanged?(absolute)
    }

    private func connectionChanged(_ connected: Bool) {
        guard session != nil else { return }
        isConnected = connected
        onConnectionChange?(connected)
    }

    private func agentChanged(_ connected: Bool) {
        guard session != nil else { return }
        agentConnected = connected
        if !connected { hostClipboardAnnounced = false }
        // Capability updates use the same notification as transport connection.
        // Let the focused view announce the current pasteboard once ready; do
        // not release/re-grab stale text on every agent capability notification.
        if !connected { clipboardCapability = false }
        if connected { agentAnnounced = true }
        onAgentChange?(connected)
    }

    func setUsingGL(_ enabled: Bool) { usingGL = enabled }

    private func receivedGuestClipboard(_ text: String) {
        guard session != nil, agentConnected, clipboardIntegrationEnabled else { return }
        // Do not re-announce an older host value if the guest agent reconnects.
        hostClipboardText = text
        hostClipboardAnnounced = false
        onGuestClipboard?(text)
    }

    /// Current guest framebuffer as an image, or nil before the first surface.
    func currentImage(onlyChanged: Bool = false, softwareOnly: Bool = false) -> CGImage? {
        if usingGL && !softwareOnly { return onlyChanged ? nil : (fallbackImage ?? activeMetalDisplay?.snapshot()) }
        guard let session else { return nil }
        var width: Int32 = 0, height: Int32 = 0
        guard let buffer = (onlyChanged ? sb_copy_changed_frame(session, &width, &height) : sb_copy_frame(session, &width, &height)) else { return nil }
        let size = Int(width) * Int(height) * 4
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size, releaseData: { _, data, _ in sb_free(UnsafeMutableRawPointer(mutating: data)) }),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { sb_free(buffer); return nil }
        return CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func makeCursor(rgba: Data, width: Int, height: Int, hotX: Int, hotY: Int) -> NSCursor? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let target = rep.bitmapData else { return nil }
        // SPICE sends premultiplied-free ARGB bytes as B,G,R,A in memory.
        rgba.withUnsafeBytes { source in
            for pixel in 0..<(width * height) {
                let base = pixel * 4
                target[base] = source[base + 2]
                target[base + 1] = source[base + 1]
                target[base + 2] = source[base]
                target[base + 3] = source[base + 3]
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return NSCursor(image: image, hotSpot: NSPoint(x: hotX, y: hotY))
    }

    // MARK: Input

    func key(_ scancode: UInt32, down: Bool) { if let session { sb_key(session, scancode, down ? 1 : 0) } }
    func pointer(x: Int, y: Int, buttons: Int) { if let session { sb_pointer_position(session, Int32(x), Int32(y), Int32(buttons)) } }
    func motion(dx: Int, dy: Int, buttons: Int) { if let session { sb_pointer_motion(session, Int32(dx), Int32(dy), Int32(buttons)) } }
    func button(_ button: Int, down: Bool, buttons: Int) { if let session { sb_button(session, Int32(button), down ? 1 : 0, Int32(buttons)) } }
    func scroll(up: Bool, buttons: Int) { if let session { sb_scroll(session, up ? 1 : 0, Int32(buttons)) } }
    func resize(width: Int, height: Int) { if let session { sb_resize(session, Int32(width), Int32(height)) } }
    func setHostClipboard(_ text: String?) {
        guard clipboardIntegrationEnabled, (text?.utf8.count ?? 0) <= 16 * 1024 * 1024 else { return }
        hostClipboardText = text
        guard let session else { return }
        guard agentConnected, clipboardCapability else { return }
        reportClipboard("已向 Windows 宣告宿主文本")
        guard let text, !text.isEmpty else {
            if hostClipboardAnnounced { sb_clipboard_set(session, nil, 0); hostClipboardAnnounced = false }
            return
        }
        hostClipboardAnnounced = true
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { sb_clipboard_set(session, $0, Int32(bytes.count)) }
        }
    }
}

/// Shows the guest framebuffer and forwards keyboard and pointer input.
@MainActor
final class WoADisplayView: NSView {
    let client: WoASpiceClient
    private var guestSize = CGSize.zero
    private var metalDisplay: WoAMetalDisplayView?
    private var preferredResolution: CGSize
    private var windowActive = true
    private var lastDisplayedFrame: CGImage?
    private var metalFailed = false
    private var surfaceGeneration = 0
    private var fullscreenFill = false
    private var buttons = 0
    private var pointerCaptured = false
    var pointerCapturedForImmersive: Bool { pointerCaptured }
    private var cursorHiddenForCapture = false
    private var relativeRemainder = CGPoint.zero
    private var pressedKeys = Set<UInt16>()
    private var pressedModifiers = Set<UInt16>()
    private var scrollRemainder: CGFloat = 0
    private var guestCursor: NSCursor?
    private var resizeWork: DispatchWorkItem?
    private var lastRequestedSize = CGSize.zero
    // Force an initial announcement even if macOS clipboard predates VM startup.
    private var lastPasteboardCount = -1
    private var lastClipboardSync = Date.distantPast
    private var clipboardTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private(set) var hasFrame = false
    var onFirstFrame: (() -> Void)?

    init(client: WoASpiceClient, preferredResolution: CGSize = CGSize(width: 1920, height: 1200)) {
        self.preferredResolution = preferredResolution
        self.client = client
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        client.onSurface = { [weak self] size in
            guard let self else { return }
            self.surfaceGeneration += 1
            self.metalDisplay?.invalidatePendingFrames()
            // Preserve the last valid picture through primary-destroy/scanout gaps.
            // Switch layers only after a replacement software frame exists.
            if size.width > 0, size.height > 0 {
                self.guestSize = size
                self.refreshFrame(force: true)
            }
        }
        client.onFrame = { [weak self] in self?.refreshFrame() }
        client.onPointerModeChanged = { [weak self] absolute in
            guard let self else { return }
            self.releaseGuestInputs()
            self.relativeRemainder = .zero
            // Absolute/tablet mode always uses the native host cursor. Switching
            // into relative mode never silently captures a global pointer.
            if absolute { self.setPointerCaptured(false) }
            self.window?.invalidateCursorRects(for: self)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipboardPollingTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
        client.onGLFrame = { [weak self] frame, complete in
            guard let self else { complete(); return }
            let generation = self.surfaceGeneration
            if self.metalFailed {
                self.presentSoftwareFallback(frame)
                complete()
                return
            }
            do {
                if self.metalDisplay == nil {
                    let view = try WoAMetalDisplayView(displayFrame: self.bounds)
                    view.autoresizingMask = [.width, .height]
                    view.isHidden = true
                    view.setDisplayActive(self.windowActive)
                    view.onRenderFailure = { [weak self] message in self?.rendererFailed(message) }
                    self.addSubview(view)
                    self.metalDisplay = view
                    self.client.activeMetalDisplay = view
                }
                self.metalDisplay!.submit(frame) { [weak self] copied in
                    defer { complete() }
                    guard let self, self.client.session != nil, self.surfaceGeneration == generation else { return }
                    guard copied else { self.presentSoftwareFallback(frame); return }
                    self.client.setUsingGL(true)
                    self.client.fallbackImage = nil
                    self.guestSize = CGSize(width: frame.width, height: frame.height)
                    self.metalDisplay?.isHidden = false
                    self.layer?.contents = nil
                    self.markFirstFrame()
                }
            } catch {
                self.rendererFailed(error.localizedDescription)
                self.presentSoftwareFallback(frame)
                complete()
            }
        }
        client.onCursor = { [weak self] cursor in
            guard let self, self.client.session != nil else { return }
            self.guestCursor = cursor ?? Self.hiddenCursor
            self.window?.invalidateCursorRects(for: self)
        }
        client.onAgentChange = { [weak self] connected in
            guard let self else { return }
            self.lastPasteboardCount = -1
            guard connected else { return }
            // main-agent-update also fires for capability updates. Do not force
            // a new Windows mode-set on each notification during GPU takeover.
            // The launch EDID already advertises the preferred windowed mode.
            self.requestGuestResize(immediately: false)
            if connected { self.syncHostClipboard(force: true) }
        }
        client.onGuestClipboard = { [weak self] text in
            guard let self, self.client.clipboardIntegrationEnabled else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.lastPasteboardCount = pasteboard.changeCount
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? NSWindow === self.window else { return }
                self.syncHostClipboard(force: false)
                self.refreshFrame(force: true)
            }
        })
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, name == NSApplication.didResignActiveNotification || note.object as? NSWindow === self.window else { return }
                    self.setPointerCaptured(false)
                }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        clipboardTimer?.invalidate()
        if pointerCaptured { CGAssociateMouseAndMouseCursorPosition(1) }
        if cursorHiddenForCapture { NSCursor.unhide() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    private static let hiddenCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    private func markFirstFrame() {
        if !hasFrame { hasFrame = true; onFirstFrame?() }
    }

    private func presentImage(_ image: CGImage) {
        lastDisplayedFrame = image
        guestSize = CGSize(width: image.width, height: image.height)
        metalDisplay?.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
        markFirstFrame()
    }

    private func refreshFrame(force: Bool = false) {
        guard !client.usingGL, windowActive else { return }
        guard force || !hasFrame || window == nil || window?.occlusionState.contains(.visible) == true else { return }
        guard let image = client.currentImage(onlyChanged: !force && hasFrame, softwareOnly: true) else { return }
        presentImage(image)
    }

    private func rendererFailed(_ message: String) {
        guard !metalFailed else { return }
        metalFailed = true
        NSLog("WoA Metal presentation failed; switching to software: %@", message)
        client.setUsingGL(false)
        refreshFrame(force: true)
    }

    private func presentSoftwareFallback(_ frame: WoAGLFrame) {
        // A GL-only guest may have no SPICE primary. Copy the IOSurface while
        // its token is owned, before complete() lets QEMU reuse the pixels.
        if let image = Self.copySoftwareFrame(frame) {
            client.setUsingGL(true)
            client.fallbackImage = image
            presentImage(image)
        } else if let image = client.currentImage(softwareOnly: true) {
            client.setUsingGL(false)
            presentImage(image)
        }
    }

    static func copySoftwareFrame(_ frame: WoAGLFrame) -> CGImage? {
        guard frame.width > 0, frame.height > 0, frame.width <= 16384, frame.height <= 16384,
              frame.bytesPerRow >= frame.width * 4,
              frame.width == IOSurfaceGetWidth(frame.surface), frame.height == IOSurfaceGetHeight(frame.surface),
              frame.bytesPerRow == IOSurfaceGetBytesPerRow(frame.surface),
              IOSurfaceGetAllocSize(frame.surface) >= frame.bytesPerRow * frame.height,
              frame.pixelFormat == 0x42475241 || frame.pixelFormat == 0x52474241,
              IOSurfaceLock(frame.surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(frame.surface, .readOnly, nil) }
        let source = IOSurfaceGetBaseAddress(frame.surface)
        let rowBytes = frame.width * 4
        var pixels = Data(count: rowBytes * frame.height)
        pixels.withUnsafeMutableBytes { target in
            guard let base = target.baseAddress else { return }
            for row in 0..<frame.height {
                let sourceRow = frame.y0top ? row : frame.height - row - 1
                memcpy(base.advanced(by: row * rowBytes), source.advanced(by: sourceRow * frame.bytesPerRow), rowBytes)
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let bitmap: CGBitmapInfo = frame.pixelFormat == 0x42475241
            ? CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
            : CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func setWindowActive(_ active: Bool) {
        if !active { setPointerCaptured(false) }
        guard windowActive != active else { return }
        windowActive = active
        metalDisplay?.setDisplayActive(active)
        if active {
            refreshFrame(force: true)
            syncHostClipboard(force: false)
        }
    }

    func setFullscreenFill(_ enabled: Bool) {
        fullscreenFill = enabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsGravity = .resizeAspect
        CATransaction.commit()
        lastRequestedSize = .zero
        requestGuestResize(immediately: true)
        if !enabled { setPointerCaptured(false) }
    }

    func setPreferredResolution(width: Int, height: Int) {
        guard width >= 640, height >= 480 else { return }
        preferredResolution = CGSize(width: width, height: height)
        lastRequestedSize = preferredResolution
        if client.agentConnected { client.resize(width: width, height: height) }
    }

    // MARK: Layout and resolution

    override func layout() {
        super.layout()
        requestGuestResize(immediately: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestGuestResize(immediately: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        if window == nil { setPointerCaptured(false) }
    }

    private func requestGuestResize(immediately: Bool) {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, self.windowActive, self.client.agentConnected else { return }
                let scale = self.window?.backingScaleFactor ?? 1
                let width = self.fullscreenFill ? Int((self.bounds.width * scale).rounded()) & ~1 : Int(self.preferredResolution.width)
                let height = self.fullscreenFill ? Int((self.bounds.height * scale).rounded()) & ~1 : Int(self.preferredResolution.height)
                guard width >= 640, height >= 480 else { return }
                let requested = CGSize(width: width, height: height)
                // Skip an already active mode, and coalesce capability/focus/layout
                // notifications into one outstanding request for each target size.
                guard requested != self.guestSize, requested != self.lastRequestedSize else { return }
                self.lastRequestedSize = requested
                NSLog("WoA resize requested %dx%d; current %.0fx%.0f", width, height, self.guestSize.width, self.guestSize.height)
                self.client.resize(width: width, height: height)
            }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0.05 : 0.35), execute: work)
    }

    // MARK: Clipboard

    private func syncHostClipboard(force: Bool) {
        guard client.clipboardIntegrationEnabled, windowActive, window?.isKeyWindow == true, NSApp.isActive else { return }
        let pasteboard = NSPasteboard.general
        guard force || pasteboard.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        client.setHostClipboard(text)
        lastClipboardSync = Date()
    }

    private func clipboardPollingTick() {
        guard windowActive, window?.isKeyWindow == true, NSApp.isActive, client.agentConnected,
              Date().timeIntervalSince(lastClipboardSync) > 0.25 else { return }
        syncHostClipboard(force: false)
    }

    // MARK: Pointer

    private var imageRect: CGRect {
        guard guestSize.width > 0, guestSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / guestSize.width, bounds.height / guestSize.height)
        let size = CGSize(width: guestSize.width * scale, height: guestSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func guestPoint(_ event: NSEvent) -> (Int, Int)? {
        guard guestSize.width > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width * guestSize.width
        let y = (point.y - rect.minY) / rect.height * guestSize.height
        return (Int(max(0, min(guestSize.width - 1, x))), Int(max(0, min(guestSize.height - 1, y))))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        if let guestCursor { addCursorRect(bounds, cursor: guestCursor) } else { addCursorRect(bounds, cursor: .arrow) }
    }

    func setPointerCaptured(_ requested: Bool) {
        // Absolute/tablet input must never disassociate the system pointer.
        let captured = requested && !client.pointerIsAbsolute && windowActive && window?.isKeyWindow == true && NSApp.isActive
        if !captured { releaseGuestInputs() }
        guard captured != pointerCaptured else { return }
        if captured {
            guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { return }
            pointerCaptured = true
            NSCursor.hide()
            cursorHiddenForCapture = true
        } else {
            pointerCaptured = false
            CGAssociateMouseAndMouseCursorPosition(1)
            if cursorHiddenForCapture { NSCursor.unhide(); cursorHiddenForCapture = false }
        }
        relativeRemainder = .zero
    }

    private func releaseGuestInputs() {
        for code in pressedKeys.union(pressedModifiers) { sendKey(code, down: false) }
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
        for (button, mask) in [(1, 1), (2, 2), (3, 4)] where buttons & mask != 0 {
            buttons &= ~mask
            client.button(button, down: false, buttons: buttons)
        }
        scrollRemainder = 0
    }

    private func sendPosition(_ event: NSEvent) {
        guard windowActive else { return }
        if client.pointerIsAbsolute {
            if let (x, y) = guestPoint(event) { client.pointer(x: x, y: y, buttons: buttons) }
        } else if pointerCaptured {
            relativeRemainder.x += event.deltaX
            relativeRemainder.y += event.deltaY
            let dx = Int(relativeRemainder.x), dy = Int(relativeRemainder.y)
            relativeRemainder.x -= CGFloat(dx)
            relativeRemainder.y -= CGFloat(dy)
            if dx != 0 || dy != 0 { client.motion(dx: dx, dy: dy, buttons: buttons) }
        }
    }

    override func mouseMoved(with event: NSEvent) { sendPosition(event) }
    override func mouseDragged(with event: NSEvent) { sendPosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPosition(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPosition(event) }

    private func press(_ event: NSEvent, spiceButton: Int, mask: Int, down: Bool) {
        window?.makeFirstResponder(self)
        if down && !client.pointerIsAbsolute { setPointerCaptured(true) }
        sendPosition(event)
        if down { buttons |= mask } else { buttons &= ~mask }
        client.button(spiceButton, down: down, buttons: buttons)
    }

    override func mouseDown(with event: NSEvent) { press(event, spiceButton: 1, mask: 1, down: true) }
    override func mouseUp(with event: NSEvent) { press(event, spiceButton: 1, mask: 1, down: false) }
    override func rightMouseDown(with event: NSEvent) { press(event, spiceButton: 3, mask: 4, down: true) }
    override func rightMouseUp(with event: NSEvent) { press(event, spiceButton: 3, mask: 4, down: false) }
    override func otherMouseDown(with event: NSEvent) { press(event, spiceButton: 2, mask: 2, down: true) }
    override func otherMouseUp(with event: NSEvent) { press(event, spiceButton: 2, mask: 2, down: false) }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollRemainder += delta
        while abs(scrollRemainder) >= step {
            client.scroll(up: scrollRemainder > 0, buttons: buttons)
            scrollRemainder += scrollRemainder > 0 ? -step : step
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        pressedKeys.insert(event.keyCode)
        sendKey(event.keyCode, down: true)
    }
    override func keyUp(with event: NSEvent) {
        pressedKeys.remove(event.keyCode)
        sendKey(event.keyCode, down: false)
    }
    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        guard Self.modifierKeyCodes.contains(code) else { return }
        if code == UInt16(kVK_CapsLock) {
            sendKey(code, down: true)
            sendKey(code, down: false)
        } else if pressedModifiers.contains(code) {
            pressedModifiers.remove(code)
            sendKey(code, down: false)
        } else {
            pressedModifiers.insert(code)
            sendKey(code, down: true)
        }
    }

    override func resignFirstResponder() -> Bool {
        setPointerCaptured(false)
        return super.resignFirstResponder()
    }

    private func sendKey(_ keyCode: UInt16, down: Bool) {
        guard let scancode = Self.scancodes[keyCode] else { return }
        client.key(scancode, down: down)
    }

    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Shift), UInt16(kVK_RightShift), UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_Option), UInt16(kVK_RightOption), UInt16(kVK_Command), 0x36, UInt16(kVK_CapsLock)
    ]

    /// macOS virtual key codes (ANSI physical layout) to PC XT set-1 scancodes; 0x100 marks an extended (E0) key.
    private static let scancodes: [UInt16: UInt32] = [
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2C, 0x07: 0x2D, 0x08: 0x2E, 0x09: 0x2F,
        0x0A: 0x56, 0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12, 0x0F: 0x13, 0x10: 0x15, 0x11: 0x14, 0x12: 0x02, 0x13: 0x03,
        0x14: 0x04, 0x15: 0x05, 0x16: 0x07, 0x17: 0x06, 0x18: 0x0D, 0x19: 0x0A, 0x1A: 0x08, 0x1B: 0x0C, 0x1C: 0x09, 0x1D: 0x0B,
        0x1E: 0x1B, 0x1F: 0x18, 0x20: 0x16, 0x21: 0x1A, 0x22: 0x17, 0x23: 0x19, 0x24: 0x1C, 0x25: 0x26, 0x26: 0x24, 0x27: 0x28,
        0x28: 0x25, 0x29: 0x27, 0x2A: 0x2B, 0x2B: 0x33, 0x2C: 0x35, 0x2D: 0x31, 0x2E: 0x32, 0x2F: 0x34, 0x30: 0x0F, 0x31: 0x39,
        0x32: 0x29, 0x33: 0x0E, 0x35: 0x01, 0x36: 0x15C, 0x37: 0x15B, 0x38: 0x2A, 0x39: 0x3A, 0x3A: 0x38, 0x3B: 0x1D, 0x3C: 0x36,
        0x3D: 0x138, 0x3E: 0x11D, 0x41: 0x53, 0x43: 0x37, 0x45: 0x4E, 0x47: 0x45, 0x4B: 0x135, 0x4C: 0x11C, 0x4E: 0x4A, 0x51: 0x59,
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B, 0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47, 0x5B: 0x48, 0x5C: 0x49,
        0x60: 0x3F, 0x61: 0x40, 0x62: 0x41, 0x63: 0x3D, 0x64: 0x42, 0x65: 0x43, 0x67: 0x57, 0x69: 0x137, 0x6B: 0x46, 0x6D: 0x44,
        0x6F: 0x58, 0x72: 0x152, 0x73: 0x147, 0x74: 0x149, 0x75: 0x153, 0x76: 0x3E, 0x77: 0x14F, 0x78: 0x3C, 0x79: 0x151,
        0x7A: 0x3B, 0x7B: 0x14B, 0x7C: 0x14D, 0x7D: 0x150, 0x7E: 0x148
    ]
}
