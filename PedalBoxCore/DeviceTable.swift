import Foundation

/// Logitech USB vendor ID. Source: Linux hid-ids.h `USB_VENDOR_ID_LOGITECH`.
public let logitechVendorID = 0x046D

public enum WheelModel: String, CaseIterable, Sendable {
    case g29, g920, g923PlayStation, g923Xbox, g27, g25, drivingForceGT, drivingForcePro, drivingForceEX
}

/// How a model is driven. lg4ff = classic 7-byte output reports; hidpp = Logitech HID++ (not implemented).
public enum ProtocolFamily: String, Sendable { case lg4ff, hidpp }

/// Controls PedalBox can offer. A control is shown for a model only after it is verified on real hardware.
public enum WheelControl: String, CaseIterable, Sendable {
    case liveInput, rotationRange, autocenter, ffbGain, ffbTest, leds
}

public struct WheelModelInfo: Sendable {
    public let model: WheelModel
    public let name: String
    /// Product IDs the model uses in its own (native) mode.
    public let nativeProductIDs: Set<Int>
    public let family: ProtocolFamily
    /// Controls confirmed on a real wheel. Empty until the user confirms each one.
    public let verifiedControls: Set<WheelControl>
    public let source: String
}

/// How a connected device was identified.
public struct WheelIdentification: Equatable, Sendable {
    public let model: WheelModel
    /// nil = native mode; otherwise the compatibility mode the wheel currently reports as.
    public let compatibilityMode: WheelModel?
}

public enum DeviceTable {
    public static let models: [WheelModelInfo] = [
        .init(model: .g29, name: "Logitech G29", nativeProductIDs: [0xC24F], family: .lg4ff,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_G29_WHEEL"),
        .init(model: .g920, name: "Logitech G920", nativeProductIDs: [0xC262], family: .hidpp,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_G920_WHEEL"),
        .init(model: .g923PlayStation, name: "Logitech G923 (PlayStation/PC)", nativeProductIDs: [0xC266, 0xC267], family: .lg4ff,
              verifiedControls: [], source: "oversteer wheel_ids.py LG_G923P; new-lg4ff README"),
        .init(model: .g923Xbox, name: "Logitech G923 (Xbox/PC)", nativeProductIDs: [0xC26E, 0xC26D], family: .hidpp,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_G923_XBOX_WHEEL; new-lg4ff README"),
        .init(model: .g27, name: "Logitech G27", nativeProductIDs: [0xC29B], family: .lg4ff,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_G27_WHEEL"),
        .init(model: .g25, name: "Logitech G25", nativeProductIDs: [0xC299], family: .lg4ff,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_G25_WHEEL"),
        .init(model: .drivingForceGT, name: "Logitech Driving Force GT", nativeProductIDs: [0xC29A], family: .lg4ff,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_DFGT_WHEEL"),
        .init(model: .drivingForcePro, name: "Logitech Driving Force Pro", nativeProductIDs: [0xC298], family: .lg4ff,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_DFP_WHEEL"),
        .init(model: .drivingForceEX, name: "Logitech Driving Force / EX", nativeProductIDs: [0xC294], family: .lg4ff,
              verifiedControls: [], source: "hid-ids.h USB_DEVICE_ID_LOGITECH_WHEEL"),
    ]

    public static func info(for model: WheelModel) -> WheelModelInfo {
        models.first { $0.model == model }!
    }

    /// Identifies a wheel from USB IDs. A G29 can enumerate under a compatibility PID; it is
    /// recognised by bcdDevice as in lg4ff_identify_multimode_wheel (hid-lg4ff.c):
    /// `bcd & 0xFFF8 == 0x1350` or `bcd & 0xFF00 == 0x8900`.
    public static func identify(vendorID: Int, productID: Int, bcdDevice: Int?) -> WheelIdentification? {
        guard vendorID == logitechVendorID else { return nil }
        guard let reported = models.first(where: { $0.nativeProductIDs.contains(productID) }) else { return nil }

        let compatPIDs: Set<Int> = [0xC294, 0xC298, 0xC299, 0xC29A, 0xC29B]
        if let bcd = bcdDevice, compatPIDs.contains(productID), isG29(bcdDevice: bcd) {
            return WheelIdentification(model: .g29, compatibilityMode: reported.model)
        }
        return WheelIdentification(model: reported.model, compatibilityMode: nil)
    }

    public static func isG29(bcdDevice bcd: Int) -> Bool {
        (bcd & 0xFFF8) == 0x1350 || (bcd & 0xFF00) == 0x8900
    }

    /// Controls to show for a device: only those verified for the detected model, and none while
    /// the wheel is in a compatibility mode.
    public static func visibleControls(for id: WheelIdentification) -> Set<WheelControl> {
        guard id.compatibilityMode == nil else { return [] }
        return info(for: id.model).verifiedControls
    }
}
