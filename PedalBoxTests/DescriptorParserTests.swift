import Testing
@testable import PedalBoxCore

/// Test vector: keyboard report descriptor from the USB "Device Class Definition for HID 1.11",
/// Appendix E.6 (Report Descriptor, Keyboard). Documented source, not a made-up descriptor.
private let hid111KeyboardDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
    0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
    0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
]

@Suite struct DescriptorParserTests {
    @Test func parsesAllItems() throws {
        let items = try HIDDescriptorParser.parse(hid111KeyboardDescriptor)
        #expect(items.count == 32)
        #expect(items.first?.name == "Usage Page")
        #expect(items.last?.name == "End Collection")
    }

    @Test func computesReportLayout() throws {
        let layout = HIDDescriptorParser.layout(of: try HIDDescriptorParser.parse(hid111KeyboardDescriptor))
        // Spec E.6: 8-byte input report (modifiers, reserved, 6 keys) and 1-byte LED output report.
        #expect(layout.inputBits == [0: 64])
        #expect(layout.outputBits == [0: 8])
        #expect(layout.featureBits.isEmpty)
    }

    @Test func rejectsTruncatedDescriptor() {
        #expect(throws: HIDDescriptorError.truncated(offset: 0)) {
            try HIDDescriptorParser.parse([0x05])
        }
    }

    @Test func dumpRoundTripsRawBytes() throws {
        let dump = HIDDescriptorParser.dump(try HIDDescriptorParser.parse(hid111KeyboardDescriptor))
        let rebuilt = dump.split(separator: "\n").flatMap { line in
            line.prefix(18).split(separator: " ").compactMap { UInt8($0, radix: 16) }
        }
        #expect(rebuilt == hid111KeyboardDescriptor)
    }
}
