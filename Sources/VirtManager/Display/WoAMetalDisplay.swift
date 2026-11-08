import AppKit
import IOSurface
import MetalKit
import CoreImage

struct WoAGLFrame {
    let surface: IOSurfaceRef
    let token: UnsafeMutableRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: UInt32
    let y0top: Bool
}

/// Copies the borrowed SPICE IOSurface before acknowledging its draw token.
/// Rendering never uses a surface that QEMU is free to overwrite.
@MainActor final class WoAMetalDisplayView: MTKView {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var textures: [MTLTexture] = []
    private var copying = Set<ObjectIdentifier>()
    private var redrawPending = false
    private var displayActive = true
    private var y0Top = true
    private var generation = 0
    private(set) var presentedFrames = 0
    var onRenderFailure: ((String) -> Void)?

    static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        // A per-draw uniform, not a function constant: orientation can change
        // between scanouts without recompiling either shader.
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 position [[position]]; float2 uv; };
        vertex VertexOut vertex_main(uint i [[vertex_id]], constant uint &top [[buffer(0)]]) {
            const float2 positions[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
            const float2 coordinates[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
            VertexOut result;
            result.position = float4(positions[i],0,1);
            result.uv = coordinates[i];
            if (top == 0) result.uv.y = 1.0 - result.uv.y;
            return result;
        }
        fragment float4 fragment_main(VertexOut v [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler linearSampler(filter::linear,address::clamp_to_edge);
            return float4(image.sample(linearSampler,v.uv).rgb,1);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "vertex_main"),
              let fragment = library.makeFunction(name: "fragment_main") else {
            throw AppFailure("Metal 显示着色器缺失")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "WoA SPICE display"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.rasterSampleCount = 1
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    init(displayFrame: CGRect) throws {
        guard let gpu = MTLCreateSystemDefaultDevice(), let queue = gpu.makeCommandQueue() else {
            throw AppFailure("Metal 显示设备不可用")
        }
        self.queue = queue
        pipeline = try Self.makePipeline(device: gpu)
        super.init(frame: displayFrame, device: gpu)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        // Draw only when a frame or geometry changes; never start an idle 60 Hz loop.
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Completion runs on the main queue, exactly once, with the copy result.
    func submit(_ frame: WoAGLFrame, completion: @escaping (Bool) -> Void) {
        guard let device, frame.width > 0, frame.height > 0,
              frame.width == IOSurfaceGetWidth(frame.surface),
              frame.height == IOSurfaceGetHeight(frame.surface),
              frame.bytesPerRow >= frame.width * 4 else { completion(false); return }
        let format: MTLPixelFormat
        switch frame.pixelFormat {
        case 0x42475241: format = .bgra8Unorm
        case 0x52474241: format = .rgba8Unorm
        default: completion(false); return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: frame.width, height: frame.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let shared = device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0) else { completion(false); return }
        descriptor.storageMode = .private
        if textures.first?.width != frame.width || textures.first?.height != frame.height || textures.first?.pixelFormat != format {
            textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        }
        guard let privateCopy = textures.first(where: { candidate in
            !copying.contains(ObjectIdentifier(candidate)) && (texture == nil || candidate !== texture!)
        }), let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { completion(false); return }
        let identity = ObjectIdentifier(privateCopy)
        copying.insert(identity)
        let submittedGeneration = generation
        blit.copy(from: shared, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0,0,0),
                  sourceSize: MTLSizeMake(frame.width,frame.height,1), to: privateCopy,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0,0,0))
        blit.endEncoding()
        command.addCompletedHandler { [weak self] completed in
            let succeeded = completed.status == .completed
            let failure = completed.error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { completion(false); return }
                self.copying.remove(identity)
                guard succeeded, self.generation == submittedGeneration else {
                    if let failure { self.onRenderFailure?(failure) }
                    completion(false)
                    return
                }
                self.texture = privateCopy
                self.y0Top = frame.y0top
                self.presentedFrames += 1
                completion(true)
                self.scheduleDraw()
            }
        }
        command.commit()
    }

    func invalidatePendingFrames() { generation += 1 }

    private func scheduleDraw() {
        guard displayActive, !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            self.draw()
        }
    }

    func setDisplayActive(_ active: Bool) {
        displayActive = active
        if active { scheduleDraw() }
    }

    static func encode(encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
                       texture: MTLTexture, width: Int, height: Int, y0Top: Bool) {
        let scale = min(Double(width) / Double(texture.width), Double(height) / Double(texture.height))
        let w = Double(texture.width) * scale, h = Double(texture.height) * scale
        encoder.setViewport(MTLViewport(originX: (Double(width)-w)/2, originY: (Double(height)-h)/2, width: w, height: h, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        var orientation: UInt32 = y0Top ? 1 : 0
        encoder.setVertexBytes(&orientation, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    override func draw(_ rect: CGRect) {
        guard displayActive, !isHidden, bounds.width > 0, bounds.height > 0,
              let texture, let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        Self.encode(encoder: encoder, pipeline: pipeline, texture: texture,
                    width: drawable.texture.width, height: drawable.texture.height, y0Top: y0Top)
        command.addCompletedHandler { [weak self] completed in
            guard completed.status == .error else { return }
            let message = completed.error?.localizedDescription ?? "Metal 提交失败"
            DispatchQueue.main.async { self?.onRenderFailure?(message) }
        }
        command.present(drawable)
        command.commit()
    }

    /// Diagnostic only. Normal presentation performs no GPU-to-CPU readback.
    func snapshot() -> CGImage? {
        guard let texture, let device else { return nil }
        // Render with the identical shader and viewport transform used on screen.
        // Core Image's coordinate convention must not introduce a second flip.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        Self.encode(encoder: encoder, pipeline: pipeline, texture: texture, width: texture.width, height: texture.height, y0Top: y0Top)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        let rowBytes = texture.width * 4
        var pixels = Data(count: rowBytes * texture.height)
        pixels.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    override func layout() { super.layout(); scheduleDraw() }
}
