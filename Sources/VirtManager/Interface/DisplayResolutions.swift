import AppKit
import CoreGraphics
import IOKit.graphics

struct DisplayResolution: Identifiable, Equatable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    var dimensions: String { "\(width) × \(height)" }
}

@MainActor enum DisplayResolutions {
    static func physicalSize(for screen: NSScreen) -> (width: Int, height: Int) {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(number.uint32Value)) {
            let display = CGDirectDisplayID(number.uint32Value)
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
            // Native flags avoid mistaking Retina points or supersampled scaled modes for panel pixels.
            if let native = modes.first(where: { $0.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }) {
                return (native.pixelWidth, native.pixelHeight)
            }
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor))
    }

    static func options(screen: NSScreen?) -> [DisplayResolution] {
        var values = [(1280, 800), (1920, 1080), (1920, 1200), (2560, 1600)].map {
            DisplayResolution(id: "\($0.0)x\($0.1)", title: "\($0.0) × \($0.1)", width: $0.0, height: $0.1)
        }
        if let screen {
            let size = physicalSize(for: screen)
            values.append(DisplayResolution(id: "host-native", title: "本机物理 · \(size.width) × \(size.height)", width: size.width, height: size.height))
            let height = size.width * 10 / 16
            values.append(DisplayResolution(id: "host-16-10", title: "忽略刘海 16:10 · \(size.width) × \(height)", width: size.width, height: height))
        }
        return values
    }
}
