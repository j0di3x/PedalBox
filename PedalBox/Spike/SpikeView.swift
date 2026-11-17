import SwiftUI
import PedalBoxCore

/// Phase 0 spike window: read-only live view of IOHID and GameController data.
struct SpikeView: View {
    @EnvironmentObject var hid: HIDMonitor
    @EnvironmentObject var gc: GCMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FFBSection()
                    Text("IOHID (what SDL / raw-HID games see)").font(.title3.bold())
                    if hid.devices.isEmpty {
                        Text(hid.status == .running ? "No Logitech device connected." : "Monitoring stopped.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(hid.devices) { HIDDeviceView(device: $0) }
                    Divider()
                    Text("GameController (what GCRacingWheel games see)").font(.title3.bold())
                    GCSectionView()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom)
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Phase 0 spike").font(.headline)
                Text("The monitor below only reads. Force feedback (when on) sends commands to the wheel.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusLabel
            if hid.status == .stopped {
                Button("Start monitoring") { hid.start(); gc.start() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Stop") { hid.stop(); gc.stop() }
            }
            Button("Export report…") { SpikeReport.export(hid: hid, gc: gc) }
                .help("Copies the report to the clipboard and offers to save it as a text file.")
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch hid.status {
        case .stopped: Label("Stopped", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .running: Label("Monitoring", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        case .needsPermission:
            VStack(alignment: .trailing) {
                Label("Input Monitoring needed", systemImage: "lock").foregroundStyle(.orange)
                Text("Allow PedalBox in System Settings › Privacy & Security › Input Monitoring, then Stop/Start.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}

private struct HIDDeviceView: View {
    @EnvironmentObject var hid: HIDMonitor
    let device: HIDDeviceSnapshot
    @State private var captureLabel = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(identText).font(.callout)
                Text(String(format: "VID 0x%04X  PID 0x%04X  bcdDevice %@", device.vendorID, device.productID,
                            device.bcdDevice.map { String(format: "0x%04X", $0) } ?? "?"))
                    .font(.caption.monospaced())
                Text("ForceFeedback.framework: \(device.forceFeedbackPlugin)").font(.caption)

                let inputs = device.elements.filter(\.isInput)
                let axes = inputs.filter(\.isAxis)
                if !axes.isEmpty {
                    Text("Axes").font(.subheadline.bold())
                    ForEach(axes) { e in
                        AxisRow(label: e.label, cookie: e.id, value: device.values[e.id] ?? 0, min: e.logicalMin, max: e.logicalMax)
                    }
                }
                ForEach(inputs.filter(\.isHat)) { e in
                    Text("Hat (cookie \(e.id)): \(device.values[e.id] ?? -1)  [range \(e.logicalMin)…\(e.logicalMax)]")
                        .font(.caption.monospaced())
                }
                let buttons = inputs.filter(\.isButton)
                if !buttons.isEmpty {
                    Text("Buttons (paddles, wheel buttons, shifter)").font(.subheadline.bold())
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 12), spacing: 6) {
                        ForEach(buttons) { b in
                            let on = (device.values[b.id] ?? 0) != 0
                            Text("\(b.usage)")
                                .font(.caption.monospaced())
                                .frame(width: 38, height: 22)
                                .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 4))
                                .foregroundStyle(on ? .white : .primary)
                        }
                    }
                }
                Text("Last input report: \(device.lastReport.map { "ID \($0.reportID): " + hexString($0.bytes) } ?? "—")  (\(device.reportCount) received)")
                    .font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    TextField("Capture label, e.g. \"wheel full left\"", text: $captureLabel)
                    Button("Capture current report") {
                        hid.capture(deviceID: device.id, label: captureLabel)
                        captureLabel = ""
                    }.disabled(device.lastReport == nil)
                }
                ForEach(device.captures) { c in
                    Text("[\(c.label)] \(hexString(c.report.bytes))").font(.caption2.monospaced()).textSelection(.enabled)
                }
                DisclosureGroup("Descriptor and properties") {
                    VStack(alignment: .leading) {
                        ForEach(device.properties, id: \.0) { Text("\($0.0): \($0.1)").font(.caption2.monospaced()) }
                        Text((try? HIDDescriptorParser.dump(HIDDescriptorParser.parse(device.descriptor))) ?? hexString(device.descriptor))
                            .font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(device.product).font(.headline)
        }
    }

    private var identText: String {
        guard let id = device.identification else { return "Not in device table" }
        let name = DeviceTable.info(for: id.model).name
        if let mode = id.compatibilityMode { return "\(name) — in \(mode.rawValue) compatibility mode" }
        return "\(name) — native mode"
    }
}

private struct AxisRow: View {
    let label: String
    let cookie: UInt32
    let value: Int
    let min: Int
    let max: Int

    var body: some View {
        HStack {
            Text("\(label)").frame(width: 90, alignment: .leading)
            ProgressView(value: InputScaling.unit(value, min: min, max: max) ?? 0)
            Text("\(value)").font(.caption.monospaced()).frame(width: 60, alignment: .trailing)
            Text("\(min)…\(max)").font(.caption2.monospaced()).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }
        .help("cookie \(cookie)")
    }
}

private struct GCSectionView: View {
    @EnvironmentObject var gc: GCMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if gc.wheels.isEmpty { Text("No GCRacingWheel connected.").foregroundStyle(.secondary) }
            ForEach(gc.wheels) { w in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(w.vendorName) — \(w.productCategory)")
                            Spacer()
                            Button(w.acquired ? "Relinquish" : "Acquire (exclusive, like a game)") { gc.toggleAcquire(w.id) }
                        }
                        Text("Inputs arrive only after acquiring. Acquiring is exclusive and may hide the wheel from other apps until relinquished.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "Max rotation: %.0f°", w.maxDegrees))
                        Text("Steering \(f(w.steering))  Accel \(f(w.accelerator))  Brake \(f(w.brake))  Clutch \(f(w.clutch))  Shifter \(w.shifter)")
                            .font(.caption.monospaced())
                        ForEach(w.elements) { Text("\($0.kind): \($0.value)").font(.caption2.monospaced()) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let err = gc.lastError { Text(err).foregroundStyle(.red) }
            Text("GCController list").font(.subheadline.bold())
            if gc.controllers.isEmpty { Text("None.").foregroundStyle(.secondary) }
            ForEach(gc.controllers) { c in
                Text("\(c.vendorName) — \(c.productCategory), \(c.profile), haptics \(c.hasHaptics ? "yes" : "no")")
                    .font(.caption.monospaced())
            }
        }
    }

    private func f(_ v: Float?) -> String { v.map { String(format: "%.3f", $0) } ?? "n/a" }
}
