import Foundation

/// Pure helpers for showing HID element values. No device access.
public enum InputScaling {
    /// Maps a raw value in [min, max] to 0...1. Returns nil for an empty range.
    public static func unit(_ value: Int, min: Int, max: Int) -> Double? {
        guard max > min else { return nil }
        let clamped = Swift.min(Swift.max(value, min), max)
        return Double(clamped - min) / Double(max - min)
    }

    /// Maps a raw value in [min, max] to -1...1 (for a centred axis such as steering).
    public static func centered(_ value: Int, min: Int, max: Int) -> Double? {
        unit(value, min: min, max: max).map { $0 * 2 - 1 }
    }

    /// Degrees from centre for a steering axis, given the wheel's configured rotation range.
    public static func steeringDegrees(_ value: Int, min: Int, max: Int, rotationRange: Double) -> Double? {
        centered(value, min: min, max: max).map { $0 * rotationRange / 2 }
    }
}
