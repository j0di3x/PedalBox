import SwiftUI
import PedalBoxCore

/// UI side of the force feedback bridge. Settings are kept in UserDefaults:
/// `ffbEnabled`, `ffbGain` (0…4), `ffbReturn` (0…1), `ffbMinimum`, `ffbInvert`. `-ffbEnabled YES` on the command line
/// (the BeamNG Launcher passes it) turns the bridge on at launch; the distributed notification
/// `local.pedalbox.ffb.enable` turns it on in a PedalBox that is already running.
@MainActor
final class FFBController: ObservableObject {
    let engine = FFBEngine()
    @Published private(set) var snap = FFBEngine.Snapshot()
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "ffbEnabled"); enabled ? engine.start() : engine.stop() } }
    @Published var gain: Double { didSet { defaults.set(gain, forKey: "ffbGain"); push() } }
    @Published var returnAmount: Double { didSet { defaults.set(returnAmount, forKey: "ffbReturn"); push() } }
    @Published var invert: Bool { didSet { defaults.set(invert, forKey: "ffbInvert"); push() } }
    @Published var minimum: Double { didSet { defaults.set(minimum, forKey: "ffbMinimum"); push() } }

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    init() {
        enabled = defaults.bool(forKey: "ffbEnabled")
        gain = defaults.object(forKey: "ffbGain") as? Double ?? 3.0      // G29 owners run BeamNG at ~300 %
        returnAmount = defaults.object(forKey: "ffbReturn") as? Double ?? 0.5
        invert = defaults.bool(forKey: "ffbInvert")
        minimum = defaults.object(forKey: "ffbMinimum") as? Double ?? 0.12
        push()
        if enabled { engine.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [engine] _ in
            engine.stop()
        }
        // BeamNG Launcher posts this when the game starts with force feedback on, in case PedalBox was already open
        DistributedNotificationCenter.default().addObserver(forName: .init("local.pedalbox.ffb.enable"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.enabled == false { self?.enabled = true } }
        }
    }

    /// True while the game has sent something in the last second.
    var receiving: Bool { snap.lastPacket.map { Date().timeIntervalSince($0) < 1 } ?? false }

    private func push() { engine.configure(gain: gain, returnAmount: returnAmount, invert: invert, minimum: minimum) }
    private func refresh() { snap = engine.snapshot() }
}

struct FFBSection: View {
    @EnvironmentObject var ffb: FFBController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $ffb.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force feedback for BeamNG (experimental)").font(.headline)
                        Text("Plays the game's steering force on the wheel. Needs the PedalBox mod, which BeamNG Launcher installs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Spacer()
            }
            if ffb.enabled {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Wheel").foregroundStyle(.secondary)
                        Text(ffb.snap.wheel ?? "No Logitech wheel found (G29, G27, G25, DFGT…)")
                    }
                    GridRow {
                        Text("Game").foregroundStyle(.secondary)
                        Text(ffb.receiving ? "Sending force" + (ffb.snap.kmh.map { String(format: " · %.0f km/h", $0) } ?? "") : "Waiting for BeamNG — sit in a car")
                    }
                    GridRow {
                        Text("Force").foregroundStyle(.secondary)
                        ForceBar(value: ffb.snap.force).frame(width: 220, height: 10)
                    }
                    GridRow {
                        Text("Strength").foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $ffb.gain, in: 0...4).frame(width: 220)
                            Text("\(Int(ffb.gain * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        .help("How strongly the game's own force (road, tyres, bumps) is played. G29 owners usually use 200–450 %.")
                    }
                    GridRow {
                        Text("Return to centre").foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $ffb.returnAmount, in: 0...1).frame(width: 220)
                            Text("\(Int(ffb.returnAmount * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        .help("Straightens the wheel after a turn, like power steering: none when standing still, strongest at town speeds, fading as the tyres take over at speed.")
                    }
                    GridRow {
                        Text("Minimum force").foregroundStyle(.secondary)
                        HStack {
                            Slider(value: $ffb.minimum, in: 0...0.3).frame(width: 220)
                            Text("\(Int(ffb.minimum * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        .help("Logitech motors ignore weak pushes. Raise this if the wheel doesn't straighten itself after a turn; lower it if the centre feels notchy.")
                    }
                    GridRow {
                        Text("Direction").foregroundStyle(.secondary)
                        HStack {
                            Toggle("Invert", isOn: $ffb.invert)
                            Button("Test left") { ffb.engine.test(-0.35) }
                            Button("Test right") { ffb.engine.test(0.35) }
                        }
                        .disabled(ffb.snap.wheel == nil)
                    }
                }
                .font(.callout)
                if let e = ffb.snap.error { Text(e).font(.caption).foregroundStyle(.orange) }
                Text("If the wheel pulls away from centre instead of towards it while driving, turn on Invert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

private struct ForceBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            let half = g.size.width / 2
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Rectangle().fill(Color.accentColor)
                    .frame(width: abs(value) * half)
                    .offset(x: value < 0 ? half - abs(value) * half : half)
                Rectangle().fill(.secondary).frame(width: 1).offset(x: half)
            }
            .clipShape(Capsule())
        }
    }
}
