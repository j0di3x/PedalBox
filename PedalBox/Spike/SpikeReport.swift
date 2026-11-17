import AppKit
import PedalBoxCore
import UniformTypeIdentifiers

/// Builds the text report the user sends back after running the spike on real hardware.
@MainActor
enum SpikeReport {
    static func text(hid: HIDMonitor, gc: GCMonitor) -> String {
        var out: [String] = []
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        out.append("PedalBox Phase 0 spike report — \(ISO8601DateFormatter().string(from: Date()))")
        out.append("macOS \(os)")
        out.append("HID status: \(hid.status)")
        out.append("")
        out.append("=== IOHID devices (vendor 0x046D) ===")
        if hid.devices.isEmpty { out.append("(none)") }
        for d in hid.devices {
            out.append("--- \(d.product) [registry 0x\(String(d.id, radix: 16))]")
            if let ident = d.identification {
                out.append("Identified: \(DeviceTable.info(for: ident.model).name)"
                           + (ident.compatibilityMode.map { " in \($0.rawValue) compatibility mode" } ?? " (native mode)"))
            } else {
                out.append("Identified: not in device table")
            }
            out.append("ForceFeedback.framework: \(d.forceFeedbackPlugin)")
            for (k, v) in d.properties { out.append("  \(k): \(v)") }
            out.append("Report descriptor (\(d.descriptor.count) bytes):")
            out.append(hexString(d.descriptor))
            if let items = try? HIDDescriptorParser.parse(d.descriptor) {
                let layout = HIDDescriptorParser.layout(of: items)
                out.append("Layout bits per report ID — input \(layout.inputBits), output \(layout.outputBits), feature \(layout.featureBits)")
                out.append(HIDDescriptorParser.dump(items))
            } else {
                out.append("(descriptor parse failed)")
            }
            out.append("Elements:")
            for e in d.elements {
                out.append(String(format: "  cookie %4u %-13@ page 0x%02X usage 0x%02X %-12@ logical %d…%d  reportID %d size %d count %d  value %@",
                                  e.id, e.type as NSString, e.usagePage, e.usage, e.label as NSString,
                                  e.logicalMin, e.logicalMax, e.reportID, e.reportSize, e.reportCount,
                                  (d.values[e.id].map(String.init) ?? "-") as NSString))
            }
            out.append("Input reports received: \(d.reportCount)")
            if let r = d.lastReport { out.append("Last input report (ID \(r.reportID)): \(hexString(r.bytes))") }
            out.append("Captures:")
            for c in d.captures { out.append("  [\(c.label)] ID \(c.report.reportID): \(hexString(c.report.bytes))") }
            out.append("")
        }
        out.append("=== GameController: GCRacingWheel ===")
        if gc.wheels.isEmpty { out.append("(none)") }
        for w in gc.wheels {
            out.append("--- \(w.vendorName) / \(w.productCategory)  acquired=\(w.acquired)")
            out.append("maximumDegreesOfRotation: \(w.maxDegrees)")
            out.append("steering \(fmt(w.steering)) accel \(fmt(w.accelerator)) brake \(fmt(w.brake)) clutch \(fmt(w.clutch)) shifter \(w.shifter)")
            out.append("Force feedback API on GCRacingWheel: none in the macOS SDK headers (no haptics property)")
            for e in w.elements { out.append("  \(e.kind): \(e.value)") }
        }
        if let err = gc.lastError { out.append("GC error: \(err)") }
        out.append("")
        out.append("=== GameController: GCController ===")
        if gc.controllers.isEmpty { out.append("(none)") }
        for c in gc.controllers {
            out.append("--- \(c.vendorName) / \(c.productCategory) profile=\(c.profile) haptics=\(c.hasHaptics) light=\(c.hasLight) battery=\(c.hasBattery)")
        }
        return out.joined(separator: "\n")
    }

    private static func fmt(_ v: Float?) -> String { v.map { String(format: "%.3f", $0) } ?? "n/a" }

    static func export(hid: HIDMonitor, gc: GCMonitor) {
        let text = text(hid: hid, gc: gc)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PedalBox-spike-report.txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
