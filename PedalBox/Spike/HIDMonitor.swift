import Foundation
import IOKit
import IOKit.hid
import ForceFeedback
import PedalBoxCore

/// Read-only IOHIDManager monitor for Logitech devices (Phase 0 spike).
/// Opens devices non-exclusively (kIOHIDOptionsTypeNone) so games still see them.
/// Never sends output or feature reports.
struct HIDElementInfo: Identifiable {
    let id: UInt32 // cookie
    let type: String
    let usagePage: Int
    let usage: Int
    let logicalMin: Int
    let logicalMax: Int
    let reportID: Int
    let reportSize: Int
    let reportCount: Int
    let isInput: Bool

    var label: String {
        switch (usagePage, usage) {
        case (0x01, 0x30): return "X"
        case (0x01, 0x31): return "Y"
        case (0x01, 0x32): return "Z"
        case (0x01, 0x33): return "Rx"
        case (0x01, 0x34): return "Ry"
        case (0x01, 0x35): return "Rz"
        case (0x01, 0x36): return "Slider"
        case (0x01, 0x39): return "Hat"
        case (0x09, let n): return "Button \(n)"
        case (0x02, 0xC4): return "Accelerator"
        case (0x02, 0xC5): return "Brake"
        case (0x02, 0xC6): return "Clutch"
        case (0x02, 0xC8): return "Steering"
        default: return String(format: "%02X:%02X", usagePage, usage)
        }
    }
    var isButton: Bool { usagePage == 0x09 }
    var isHat: Bool { usagePage == 0x01 && usage == 0x39 }
    var isAxis: Bool { !isButton && !isHat && logicalMax - logicalMin > 1 && reportCount == 1 }
}

struct RawReport {
    let time: Date
    let reportID: UInt32
    let bytes: [UInt8]
}

struct Capture: Identifiable {
    let id = UUID()
    let label: String
    let report: RawReport
}

struct HIDDeviceSnapshot: Identifiable {
    let id: UInt64 // registry entry ID
    var properties: [(String, String)]
    var vendorID: Int
    var productID: Int
    var bcdDevice: Int?
    var product: String
    var descriptor: [UInt8]
    var elements: [HIDElementInfo]
    var values: [UInt32: Int] = [:]
    var lastReport: RawReport?
    var reportCount = 0
    var captures: [Capture] = []
    var forceFeedbackPlugin: String
    var identification: WheelIdentification? {
        DeviceTable.identify(vendorID: vendorID, productID: productID, bcdDevice: bcdDevice)
    }
}

@MainActor
final class HIDMonitor: ObservableObject {
    enum Status: Equatable { case stopped, running, needsPermission, failed(String) }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var devices: [HIDDeviceSnapshot] = []

    private var manager: IOHIDManager?
    private var live: [UInt64: HIDDeviceSnapshot] = [:]
    private var sinks: [UInt64: ReportSink] = [:]
    private var refreshPending = false

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: logitechVendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            let me = Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            let me = Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            let me = Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.valueChanged(value) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        switch result {
        case kIOReturnSuccess:
            status = .running
        case kIOReturnNotPermitted:
            // Permission is requested only now, when the spike actually needs it.
            status = .needsPermission
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        default:
            status = .failed(String(format: "IOHIDManagerOpen 0x%08X", result))
        }
    }

    func stop() {
        guard let m = manager else { return }
        for (id, sink) in sinks { sink.unregister(); sinks[id] = nil }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        live = [:]
        devices = []
        status = .stopped
    }

    func capture(deviceID: UInt64, label: String) {
        guard var d = live[deviceID], let r = d.lastReport else { return }
        d.captures.append(Capture(label: label.isEmpty ? "capture \(d.captures.count + 1)" : label, report: r))
        live[deviceID] = d
        publish()
    }

    // MARK: - Callbacks

    private func added(_ device: IOHIDDevice) {
        let id = registryID(device)
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let keys = [kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDVendorIDKey, kIOHIDProductIDKey,
                    kIOHIDVersionNumberKey, kIOHIDTransportKey, kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey,
                    kIOHIDMaxInputReportSizeKey, kIOHIDMaxOutputReportSizeKey, kIOHIDMaxFeatureReportSizeKey,
                    kIOHIDLocationIDKey, kIOHIDReportIntervalKey, "bInterfaceNumber", kIOHIDDeviceUsagePairsKey]
        var props: [(String, String)] = keys.compactMap { k in
            guard let v = prop(k) else { return nil }
            if let n = v as? Int { return (k, String(format: "%d (0x%X)", n, n)) }
            return (k, "\(v)".replacingOccurrences(of: "\n", with: " "))
        }
        let service = IOHIDDeviceGetService(device)
        var className = [CChar](repeating: 0, count: 128)
        if IOObjectGetClass(service, &className) == KERN_SUCCESS {
            props.append(("IOService class", String(cString: className)))
        }

        let elements = (IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? [])
            .compactMap(elementInfo)

        var snap = HIDDeviceSnapshot(
            id: id, properties: props,
            vendorID: prop(kIOHIDVendorIDKey) as? Int ?? 0,
            productID: prop(kIOHIDProductIDKey) as? Int ?? 0,
            bcdDevice: prop(kIOHIDVersionNumberKey) as? Int,
            product: prop(kIOHIDProductKey) as? String ?? "Unknown",
            descriptor: [UInt8](prop(kIOHIDReportDescriptorKey) as? Data ?? Data()),
            elements: elements,
            forceFeedbackPlugin: forceFeedbackStatus(service))
        for e in elements where e.isInput { snap.values[e.id] = 0 }
        live[id] = snap

        let size = max(prop(kIOHIDMaxInputReportSizeKey) as? Int ?? 64, 1)
        let sink = ReportSink(monitor: self, deviceID: id, device: device, size: size)
        sinks[id] = sink
        publish()
    }

    private func removed(_ device: IOHIDDevice) {
        let id = registryID(device)
        sinks[id]?.unregister()
        sinks[id] = nil
        live[id] = nil
        publish()
    }

    private func valueChanged(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let id = registryID(IOHIDElementGetDevice(element))
        guard live[id] != nil else { return }
        live[id]!.values[IOHIDElementGetCookie(element)] = IOHIDValueGetIntegerValue(value)
        scheduleRefresh()
    }

    fileprivate func report(deviceID: UInt64, reportID: UInt32, bytes: [UInt8]) {
        guard live[deviceID] != nil else { return }
        live[deviceID]!.lastReport = RawReport(time: Date(), reportID: reportID, bytes: bytes)
        live[deviceID]!.reportCount += 1
        scheduleRefresh()
    }

    /// Coalesces UI updates to ≤30 Hz; nothing runs while the wheel is idle.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            self?.refreshPending = false
            self?.publish()
        }
    }

    private func publish() {
        devices = live.values.sorted { $0.id < $1.id }
    }

    // MARK: - Helpers

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private func elementInfo(_ e: IOHIDElement) -> HIDElementInfo? {
        let type = IOHIDElementGetType(e)
        let typeName: String
        var isInput = false
        switch type {
        case kIOHIDElementTypeInput_Misc: typeName = "Input/Misc"; isInput = true
        case kIOHIDElementTypeInput_Button: typeName = "Input/Button"; isInput = true
        case kIOHIDElementTypeInput_Axis: typeName = "Input/Axis"; isInput = true
        case kIOHIDElementTypeInput_ScanCodes: typeName = "Input/ScanCodes"; isInput = true
        case kIOHIDElementTypeOutput: typeName = "Output"
        case kIOHIDElementTypeFeature: typeName = "Feature"
        case kIOHIDElementTypeCollection: return nil
        default: typeName = "Other(\(type.rawValue))"
        }
        return HIDElementInfo(
            id: IOHIDElementGetCookie(e), type: typeName,
            usagePage: Int(IOHIDElementGetUsagePage(e)), usage: Int(IOHIDElementGetUsage(e)),
            logicalMin: IOHIDElementGetLogicalMin(e), logicalMax: IOHIDElementGetLogicalMax(e),
            reportID: Int(IOHIDElementGetReportID(e)), reportSize: Int(IOHIDElementGetReportSize(e)),
            reportCount: Int(IOHIDElementGetReportCount(e)), isInput: isInput)
    }

    /// Asks ForceFeedback.framework whether any FF plug-in claims this device (what a macOS
    /// game using FFCreateDevice would find). Query only; no device is created.
    private func forceFeedbackStatus(_ service: io_service_t) -> String {
        let r = FFIsForceFeedback(service)
        return r == 0 ? "FF plug-in present (FFIsForceFeedback = FF_OK)"
                      : String(format: "no FF plug-in (FFIsForceFeedback = 0x%08X)", UInt32(bitPattern: r))
    }
}

/// Owns the input-report buffer for one device and forwards raw input reports.
private final class ReportSink {
    weak var monitor: HIDMonitor?
    let deviceID: UInt64
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let size: Int

    @MainActor init(monitor: HIDMonitor, deviceID: UInt64, device: IOHIDDevice, size: Int) {
        self.monitor = monitor
        self.deviceID = deviceID
        self.device = device
        self.size = size
        buffer = .allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { ctx, _, _, _, reportID, report, length in
            let sink = Unmanaged<ReportSink>.fromOpaque(ctx!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated {
                sink.monitor?.report(deviceID: sink.deviceID, reportID: reportID, bytes: bytes)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func unregister() {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, nil, nil)
    }

    deinit { buffer.deallocate() }
}
