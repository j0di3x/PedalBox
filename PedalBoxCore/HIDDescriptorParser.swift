import Foundation

/// Minimal HID report descriptor parser (USB HID 1.11, section 6.2.2) for readable dumps.
/// Read-only; never used to build output reports.
public struct HIDDescriptorItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case main, global, local, reserved, long }
    public let offset: Int
    public let kind: Kind
    public let tag: UInt8
    public let data: [UInt8]

    /// Unsigned little-endian value of the item data.
    public var unsignedValue: UInt32 {
        data.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    /// Signed value (sign-extended from the item's data size).
    public var signedValue: Int32 {
        switch data.count {
        case 1: return Int32(Int8(bitPattern: data[0]))
        case 2: return Int32(Int16(bitPattern: UInt16(unsignedValue)))
        case 4: return Int32(bitPattern: unsignedValue)
        default: return 0
        }
    }

    public var name: String {
        switch (kind, tag) {
        case (.main, 0x8): return "Input"
        case (.main, 0x9): return "Output"
        case (.main, 0xB): return "Feature"
        case (.main, 0xA): return "Collection"
        case (.main, 0xC): return "End Collection"
        case (.global, 0x0): return "Usage Page"
        case (.global, 0x1): return "Logical Minimum"
        case (.global, 0x2): return "Logical Maximum"
        case (.global, 0x3): return "Physical Minimum"
        case (.global, 0x4): return "Physical Maximum"
        case (.global, 0x5): return "Unit Exponent"
        case (.global, 0x6): return "Unit"
        case (.global, 0x7): return "Report Size"
        case (.global, 0x8): return "Report ID"
        case (.global, 0x9): return "Report Count"
        case (.global, 0xA): return "Push"
        case (.global, 0xB): return "Pop"
        case (.local, 0x0): return "Usage"
        case (.local, 0x1): return "Usage Minimum"
        case (.local, 0x2): return "Usage Maximum"
        case (.long, _): return "Long Item"
        default: return "Item(\(kind), tag 0x\(String(tag, radix: 16)))"
        }
    }
}

public struct HIDReportLayout: Equatable, Sendable {
    /// Total bits per report ID (0 = no report ID) for each main item type.
    public var inputBits: [UInt8: Int] = [:]
    public var outputBits: [UInt8: Int] = [:]
    public var featureBits: [UInt8: Int] = [:]
}

public enum HIDDescriptorError: Error, Equatable { case truncated(offset: Int) }

public enum HIDDescriptorParser {
    public static func parse(_ bytes: [UInt8]) throws -> [HIDDescriptorItem] {
        var items: [HIDDescriptorItem] = []
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE { // long item: FE, bDataSize, bLongItemTag, data
                guard i + 2 < bytes.count else { throw HIDDescriptorError.truncated(offset: i) }
                let size = Int(bytes[i + 1])
                guard i + 3 + size <= bytes.count else { throw HIDDescriptorError.truncated(offset: i) }
                items.append(.init(offset: i, kind: .long, tag: bytes[i + 2], data: Array(bytes[(i + 3)..<(i + 3 + size)])))
                i += 3 + size
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode
            guard i + 1 + size <= bytes.count else { throw HIDDescriptorError.truncated(offset: i) }
            let kind: HIDDescriptorItem.Kind
            switch (prefix >> 2) & 0x03 {
            case 0: kind = .main
            case 1: kind = .global
            case 2: kind = .local
            default: kind = .reserved
            }
            items.append(.init(offset: i, kind: kind, tag: prefix >> 4, data: Array(bytes[(i + 1)..<(i + 1 + size)])))
            i += 1 + size
        }
        return items
    }

    /// Sums Report Size × Report Count per main item and report ID. Handles Push/Pop.
    public static func layout(of items: [HIDDescriptorItem]) -> HIDReportLayout {
        struct Globals { var size = 0; var count = 0; var id: UInt8 = 0 }
        var g = Globals()
        var stack: [Globals] = []
        var layout = HIDReportLayout()
        for item in items {
            switch (item.kind, item.tag) {
            case (.global, 0x7): g.size = Int(item.unsignedValue)
            case (.global, 0x9): g.count = Int(item.unsignedValue)
            case (.global, 0x8): g.id = UInt8(truncatingIfNeeded: item.unsignedValue)
            case (.global, 0xA): stack.append(g)
            case (.global, 0xB): if let top = stack.popLast() { g = top }
            case (.main, 0x8): layout.inputBits[g.id, default: 0] += g.size * g.count
            case (.main, 0x9): layout.outputBits[g.id, default: 0] += g.size * g.count
            case (.main, 0xB): layout.featureBits[g.id, default: 0] += g.size * g.count
            default: break
            }
        }
        return layout
    }

    /// Indented, human-readable dump.
    public static func dump(_ items: [HIDDescriptorItem]) -> String {
        var depth = 0
        var lines: [String] = []
        for item in items {
            if item.kind == .main, item.tag == 0xC { depth = max(0, depth - 1) }
            let raw = ([item.kind == .long ? 0xFE : prefixByte(item)] + item.data).map(hex).joined(separator: " ")
            let value: String
            switch (item.kind, item.tag) {
            case (.global, 0x1), (.global, 0x3): value = "\(item.signedValue)"
            case (.main, 0xC): value = ""
            case (.main, 0x8), (.main, 0x9), (.main, 0xB): value = mainFlags(item.unsignedValue)
            case (.global, 0x0): value = "0x" + String(item.unsignedValue, radix: 16, uppercase: true)
            case (.local, 0x0), (.local, 0x1), (.local, 0x2): value = "0x" + String(item.unsignedValue, radix: 16, uppercase: true)
            default: value = "\(item.unsignedValue)"
            }
            let indent = String(repeating: "  ", count: depth)
            lines.append(raw.padding(toLength: 18, withPad: " ", startingAt: 0) + indent + item.name + (value.isEmpty ? "" : " (\(value))"))
            if item.kind == .main, item.tag == 0xA { depth += 1 }
        }
        return lines.joined(separator: "\n")
    }

    private static func prefixByte(_ item: HIDDescriptorItem) -> UInt8 {
        let type: UInt8 = switch item.kind { case .main: 0; case .global: 1; case .local: 2; default: 3 }
        let size: UInt8 = item.data.count == 4 ? 3 : UInt8(item.data.count)
        return item.tag << 4 | type << 2 | size
    }

    private static func mainFlags(_ v: UInt32) -> String {
        [(v & 1 != 0) ? "Const" : "Data",
         (v & 2 != 0) ? "Var" : "Array",
         (v & 4 != 0) ? "Rel" : "Abs"].joined(separator: ",")
    }
}

public func hex(_ b: UInt8) -> String { String(format: "%02X", b) }
public func hexString(_ bytes: some Sequence<UInt8>) -> String { bytes.map(hex).joined(separator: " ") }
