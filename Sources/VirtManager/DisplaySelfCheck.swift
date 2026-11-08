import AppKit
import IOSurface
import MetalKit

/// Explicit opt-in diagnostics: no VM, disk image, foreground window or clipboard changes.
@MainActor enum DisplaySelfCheck {
    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw AppFailure("Display check requires a Metal device")
        }
        print("Display check GPU: \(device.name)")
        let pipeline = try WoAMetalDisplayView.makePipeline(device: device)
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        guard let source = device.makeTexture(descriptor: sourceDescriptor) else { throw AppFailure("source texture unavailable") }
        // Two red top pixels, two blue bottom pixels.
        let pixels: [UInt8] = [0,0,255,255, 0,0,255,255, 255,0,0,255, 255,0,0,255]
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,2,2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        for top in [true, false] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            guard let destination = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
                throw AppFailure("offscreen render target unavailable")
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw AppFailure("render encoder unavailable") }
            WoAMetalDisplayView.encode(encoder: encoder, pipeline: pipeline, texture: source, width: 4, height: 4, y0Top: top)
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw AppFailure("GPU render failed: \(command.error?.localizedDescription ?? "unknown")") }
            var result = [UInt8](repeating: 0, count: 64)
            result.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0,0,4,4), mipmapLevel: 0) }
            let expectedTop = top ? Array(pixels[0..<4]) : Array(pixels[8..<12])
            let expectedBottom = top ? Array(pixels[8..<12]) : Array(pixels[0..<4])
            try require(Array(result[0..<4]) == expectedTop && Array(result[48..<52]) == expectedBottom, "Metal orientation y0top=\(top)")
            print("PASS: GPU render and pixel readback y0top=\(top)")
        }

        let properties: [String: Any] = [
            kIOSurfaceWidth as String: 2, kIOSurfaceHeight as String: 2,
            kIOSurfaceBytesPerElement as String: 4, kIOSurfaceBytesPerRow as String: 16,
            kIOSurfaceAllocSize as String: 32, kIOSurfacePixelFormat as String: 0x42475241
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary),
              IOSurfaceLock(surface, [], nil) == kIOReturnSuccess else {
            throw AppFailure("test IOSurface unavailable")
        }
        let base = IOSurfaceGetBaseAddress(surface)
        pixels.withUnsafeBytes { data in
            memcpy(base, data.baseAddress!, 8)
            memcpy(base.advanced(by: IOSurfaceGetBytesPerRow(surface)), data.baseAddress!.advanced(by: 8), 8)
        }
        IOSurfaceUnlock(surface, [], nil)
        func frame(top: Bool, format: UInt32 = 0x42475241) -> WoAGLFrame {
            WoAGLFrame(surface: surface, token: UnsafeMutableRawPointer(bitPattern: 1)!, width: 2, height: 2,
                       bytesPerRow: IOSurfaceGetBytesPerRow(surface), pixelFormat: format, y0top: top)
        }
        for top in [true, false] {
            guard let image = WoADisplayView.copySoftwareFrame(frame(top: top)), let data = image.dataProvider?.data else {
                throw AppFailure("software fallback failed")
            }
            let bytes = CFDataGetBytePtr(data)!
            let first = Array(UnsafeBufferPointer(start: bytes, count: 4))
            try require(first == (top ? Array(pixels[0..<4]) : Array(pixels[8..<12])), "software orientation")
        }
        try require(WoADisplayView.copySoftwareFrame(frame(top: true, format: 0)) == nil, "reject unsupported IOSurface formats")
        print("PASS: software IOSurface fallback, row padding and both orientations")

        let view = try WoAMetalDisplayView(displayFrame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.setDisplayActive(false)
        var completed = 0
        var success = false
        view.submit(frame(top: true)) { copied in completed += 1; success = copied }
        try pump(until: { completed == 1 })
        try require(success && view.presentedFrames == 1 && view.snapshot() != nil, "retain hidden-window GL frame")
        var staleCompleted = 0
        var staleAccepted = true
        view.submit(frame(top: false)) { copied in staleCompleted += 1; staleAccepted = copied }
        view.invalidatePendingFrames()
        try pump(until: { staleCompleted == 1 })
        try require(!staleAccepted && view.presentedFrames == 1, "discard obsolete scanout completion")
        view.submit(frame(top: true, format: 0)) { copied in completed += 1; success = copied }
        try require(completed == 2 && !success, "exactly-once completion on unsupported format")
        print("PASS: hidden-window copy, stale frame invalidation and failure completion")
        for top in [true, false] {
            var finished = false
            var accepted = false
            view.submit(frame(top: top)) { copied in accepted = copied; finished = true }
            try pump(until: { finished })
            guard accepted, let snapshot = view.snapshot(),
                  let software = WoADisplayView.copySoftwareFrame(frame(top: top)) else {
                throw AppFailure("snapshot orientation fixture failed")
            }
            let captured = NSBitmapImageRep(cgImage: snapshot)
            let reference = NSBitmapImageRep(cgImage: software)
            for row in 0..<2 {
                guard let actual = captured.colorAt(x: 0, y: row)?.usingColorSpace(.deviceRGB),
                      let expected = reference.colorAt(x: 0, y: row)?.usingColorSpace(.deviceRGB) else {
                    throw AppFailure("snapshot pixel conversion failed")
                }
                try require(abs(actual.redComponent - expected.redComponent) < 0.01 &&
                            abs(actual.blueComponent - expected.blueComponent) < 0.01, "snapshot must match GPU and software orientation")
            }
        }
        print("PASS: diagnostic snapshot orientation matches software and GPU in both directions")
        print("PASS: display self-check (offscreen; not a Windows guest certification)")
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw AppFailure("Display regression: \(message)") }
    }

    private static func pump(until ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !ready(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try require(ready(), "GPU completion timed out")
    }
}
