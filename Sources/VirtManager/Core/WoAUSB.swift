import Foundation
import IOKit
import IOKit.usb

/// A stable-enough host USB identity persisted in a WoA package.
public struct WoAUSBSelection: Codable, Equatable, Hashable, Identifiable {
    public var vendorID: Int?
    public var productID: Int?
    public var bus: Int?
    public var address: Int?

    public init(vendorID: Int? = nil, productID: Int? = nil, bus: Int? = nil, address: Int? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.bus = bus
        self.address = address
    }

    public var id: String { key }
    public var key: String {
        [vendorID.map { String(format: "%04x", $0) } ?? "----",
         productID.map { String(format: "%04x", $0) } ?? "----",
         bus.map(String.init) ?? "-", address.map(String.init) ?? "-"].joined(separator: ":")
    }

    public func matches(_ device: WoAUSBDevice) -> Bool {
        if let vendorID, device.vendorID != vendorID { return false }
        if let productID, device.productID != productID { return false }
        if let bus, device.bus != bus { return false }
        // USB addresses change after unplug/replug; match the saved VID/PID again on reconnect.
        if vendorID == nil, productID == nil, let address, device.address != address { return false }
        return vendorID != nil || productID != nil || bus != nil || address != nil
    }

    public var qemuArguments: String {
        if let vendorID, let productID {
            return String(format: "-device usb-host,vendorid=0x%04x,productid=0x%04x", vendorID, productID)
        }
        if let bus, let address { return "-device usb-host,hostbus=\(bus),hostaddr=\(address)" }
        return ""
    }
}

/// A host USB device safe to present in the WoA settings panel.
public struct WoAUSBDevice: Identifiable, Equatable, Hashable {
    public let selection: WoAUSBSelection
    public let name: String
    public let manufacturer: String?
    public var id: String { selection.key }
    public var vendorID: Int? { selection.vendorID }
    public var productID: Int? { selection.productID }
    public var bus: Int? { selection.bus }
    public var address: Int? { selection.address }
    public var detail: String {
        let ids = [vendorID, productID].compactMap { $0 }.map { String(format: "%04X", $0) }.joined(separator: ":")
        let path = [bus, address].compactMap { $0 }.map(String.init).joined(separator: "/")
        return [ids.isEmpty ? nil : "ID \(ids)", path.isEmpty ? nil : "bus/address \(path)"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Enumerates physical USB devices and watches for bounded changes. It intentionally excludes hubs and HID devices.
@MainActor
public final class WoAUSBInventory: ObservableObject {
    @Published public private(set) var devices: [WoAUSBDevice] = []
    private var timer: Timer?
    private var onNewDevices: (([WoAUSBDevice]) -> Void)?

    public init() { refresh() }
    deinit { timer?.invalidate() }

    public func refresh() {
        Task {
            let current = await Task.detached(priority: .utility) { Self.enumerate() }.value
            let previous = Set(devices)
            devices = current
            let added = current.filter { !previous.contains($0) }
            onNewDevices?(added)
        }
    }

    public func startPolling(interval: TimeInterval = 2, onNewDevices: (([WoAUSBDevice]) -> Void)? = nil) {
        self.onNewDevices = onNewDevices
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    public func stopPolling() { timer?.invalidate(); timer = nil; onNewDevices = nil }

    nonisolated private static func enumerate() -> [WoAUSBDevice] {
        var matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matching[kIOProviderClassKey] = kIOUSBDeviceClassName
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [WoAUSBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else { continue }
            let deviceClass = (dict[kUSBDeviceClass] as? NSNumber)?.intValue ?? 0
            let isHub = deviceClass == 9
            let isHID = (dict["USB Product Name"] as? String)?.localizedCaseInsensitiveContains("keyboard") == true || (dict["USB Product Name"] as? String)?.localizedCaseInsensitiveContains("mouse") == true
            guard !isHub, !isHID, deviceClass != 3 else { continue }
            let vendor = (dict[kUSBVendorID] as? NSNumber)?.intValue
            let product = (dict[kUSBProductID] as? NSNumber)?.intValue
            let bus = (dict["USB Bus Number"] as? NSNumber)?.intValue
            let address = (dict[kUSBDevicePropertyAddress] as? NSNumber)?.intValue
            guard vendor != nil || product != nil || (bus != nil && address != nil) else { continue }
            let productName = (dict[kUSBProductString] as? String) ?? "USB device"
            let manufacturer = dict[kUSBVendorString] as? String
            result.append(WoAUSBDevice(selection: WoAUSBSelection(vendorID: vendor, productID: product, bus: bus, address: address), name: productName, manufacturer: manufacturer))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
