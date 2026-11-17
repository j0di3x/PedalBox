import Testing
@testable import PedalBoxCore

/// IDs and bcdDevice masks from Linux hid-ids.h / hid-lg4ff.c (see docs/RESEARCH.md).
@Suite struct DeviceTableTests {
    @Test(arguments: [
        (0xC24F, WheelModel.g29), (0xC262, .g920), (0xC26E, .g923Xbox), (0xC266, .g923PlayStation),
        (0xC29B, .g27), (0xC299, .g25),
    ])
    func identifiesNativeIDs(pid: Int, model: WheelModel) {
        #expect(DeviceTable.identify(vendorID: 0x046D, productID: pid, bcdDevice: nil)
                == WheelIdentification(model: model, compatibilityMode: nil))
    }

    @Test func ignoresOtherVendors() {
        #expect(DeviceTable.identify(vendorID: 0x054C, productID: 0xC24F, bcdDevice: nil) == nil)
    }

    /// lg4ff_identify_multimode_wheel: G29 matches mask 0xFFF8 → 0x1350 or mask 0xFF00 → 0x8900.
    @Test func recognisesG29InCompatibilityMode() {
        #expect(DeviceTable.identify(vendorID: 0x046D, productID: 0xC294, bcdDevice: 0x1350)
                == WheelIdentification(model: .g29, compatibilityMode: .drivingForceEX))
        #expect(DeviceTable.identify(vendorID: 0x046D, productID: 0xC294, bcdDevice: 0x8900)
                == WheelIdentification(model: .g29, compatibilityMode: .drivingForceEX))
        #expect(DeviceTable.isG29(bcdDevice: 0x1357))
        #expect(!DeviceTable.isG29(bcdDevice: 0x1358))
    }

    @Test func showsNoUnverifiedControls() {
        for info in DeviceTable.models {
            #expect(DeviceTable.visibleControls(for: .init(model: info.model, compatibilityMode: nil)).isEmpty)
        }
    }
}

@Suite struct InputScalingTests {
    @Test func scalesRange() {
        #expect(InputScaling.unit(0, min: 0, max: 255) == 0)
        #expect(InputScaling.unit(255, min: 0, max: 255) == 1)
        #expect(InputScaling.unit(300, min: 0, max: 255) == 1)
        #expect(InputScaling.unit(5, min: 5, max: 5) == nil)
        #expect(InputScaling.centered(0, min: 0, max: 100) == -1)
        #expect(InputScaling.steeringDegrees(100, min: 0, max: 100, rotationRange: 900) == 450)
    }
}
