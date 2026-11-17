import Foundation

/// Classic Logitech (lg4ff) output commands, as byte arrays. Pure data, no device access.
/// Byte values are protocol facts from docs/RESEARCH.md (Linux hid-lg4ff.c); no code is copied.
/// Status: constant force / stop / autocenter-off are being tried on a G29 (native mode, interface 0).
public enum LG4FF {
    /// A command is 7 bytes; the G29's interface-0 output report (ID 0) is 16 bytes, so it's padded with zeros.
    public static let commandLength = 7

    /// Pads a command to the device's output report size.
    public static func report(_ command: [UInt8], length: Int) -> [UInt8] {
        let n = max(length, command.count)
        return command + [UInt8](repeating: 0, count: n - command.count)
    }

    /// Constant force in slot 1. `level` is -1...1 (0 = none, + = push right); the byte is 0x80 − level·127.
    /// Checked on a G29: bytes above 0x80 push left.
    public static func constantForce(_ level: Double) -> [UInt8] {
        [0x11, 0x08, forceByte(level), 0x80, 0x00, 0x00, 0x00]
    }

    public static func forceByte(_ level: Double) -> UInt8 {
        guard level.isFinite else { return 0x80 }
        let l = min(max(level, -1), 1)
        return UInt8(clamping: 0x80 - Int((l * 127).rounded()))
    }

    /// Stops slot 1.
    public static let stopForce: [UInt8] = [0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    /// Turns the wheel's own centering spring off, so only the game's force is felt.
    public static let autocenterOff: [UInt8] = [0xF5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    /// Sets the centering spring to zero strength (`fe 0d a a b` with a = b = 0), a second way to
    /// keep it from pulling, in case the wheel ignores `autocenterOff`.
    public static let autocenterZero: [UInt8] = [0xFE, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00]
}

/// Logitech motors ignore small forces (friction and a dead zone in the firmware), so the gentle
/// self-centering of a car never reaches the hands. `boost` lifts any real force to at least
/// `minimum`, keeping the shape above it. Below `ramp` it fades linearly to 0, so tiny noise
/// around the centre doesn't make the wheel buzz between left and right.
public enum DeadZone {
    public static let ramp = 0.02

    public static func boost(_ level: Double, minimum: Double) -> Double {
        let m = min(max(minimum, 0), 0.5)
        let a = min(abs(level), 1)
        guard m > 0, a > 0 else { return level }
        let out = a < ramp ? (a / ramp) * (m + ramp * (1 - m)) : m + a * (1 - m)
        return level < 0 ? -out : out
    }
}

/// Return-to-centre assist, like the "active return" of electric power steering.
///
/// A real car straightens its wheel through the tyres' self-aligning torque. That torque is small at
/// low speed (so the wheel returns slowly or sticks on friction) and grows with speed. Power steering
/// adds a return push that is strongest at low speed and fades as speed rises, where the tyres take
/// over. BeamNG already sends the tyre force; this adds the power-steering part on top.
/// Units match the game force: -1...1, + = push right. `steer` is -1...1 of full lock, + = right.
public enum SteeringReturn {
    /// How much of the assist applies at a speed: none when standing (parked cars don't self-centre),
    /// full from 10 km/h, fading to 30 % at 80 km/h and above.
    public static func speedGain(kmh v: Double) -> Double {
        if v < 2 { return 0 }
        if v < 10 { return (v - 2) / 8 }
        if v < 80 { return 1 - 0.7 * (v - 10) / 70 }
        return 0.3
    }

    /// `rate` is how fast the steering moves (full locks per second); the damping part keeps the
    /// wheel from overshooting the centre when it springs back. `amount` is the user's 0...1 setting.
    public static func force(steer: Double, kmh: Double, rate: Double, amount: Double) -> Double {
        let k = speedGain(kmh: kmh) * min(max(amount, 0), 1) * 0.6
        guard k > 0, steer.isFinite, rate.isFinite else { return 0 }
        let spring = -k * steer
        let damping = -k * 0.15 * rate
        return min(max(spring + damping, -0.6), 0.6)
    }
}

/// The tiny UDP message the BeamNG mod sends: ASCII `PBF1 <force> [<steering> [<speed m/s>]]`.
public enum FFBPacket {
    public static let port: UInt16 = 47290
    public static let magic = "PBF1"

    public static func parse(_ data: Data) -> Double? {
        guard data.count <= 64, let s = String(data: data, encoding: .ascii) else { return nil }
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard (2...4).contains(parts.count), parts[0] == magic,
              let v = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite else { return nil }
        return min(max(v, -1), 1)
    }

    /// The steering position the mod sent with the force, if any (used for the diagnostic log).
    public static func steering(_ data: Data) -> Double? { field(data, 2) }

    /// The car's speed in m/s, if the mod sent it.
    public static func speed(_ data: Data) -> Double? { field(data, 3) }

    private static func field(_ data: Data, _ i: Int) -> Double? {
        guard let s = String(data: data, encoding: .ascii) else { return nil }
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > i, parts.count <= 4, parts[0] == magic,
              let v = Double(parts[i].trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite else { return nil }
        return v
    }
}
