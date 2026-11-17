import Foundation
import GameController

/// What Apple's GameController framework exposes for the wheel (Phase 0 spike).
/// Reads properties only. Acquiring the wheel (exclusive, like a game) is an explicit user action.
struct GCElementInfo: Identifiable {
    let id: String
    let kind: String
    let value: String
}

struct GCWheelSnapshot: Identifiable {
    let id: ObjectIdentifier
    let vendorName: String
    let productCategory: String
    let acquired: Bool
    let maxDegrees: Float
    let steering: Float?
    let accelerator: Float?
    let brake: Float?
    let clutch: Float?
    let shifter: String
    let elements: [GCElementInfo]
}

struct GCControllerSnapshot: Identifiable {
    let id: ObjectIdentifier
    let vendorName: String
    let productCategory: String
    let profile: String
    let hasHaptics: Bool
    let hasLight: Bool
    let hasBattery: Bool
}

@MainActor
final class GCMonitor: ObservableObject {
    @Published private(set) var wheels: [GCWheelSnapshot] = []
    @Published private(set) var controllers: [GCControllerSnapshot] = []
    @Published private(set) var lastError: String?

    private var observers: [NSObjectProtocol] = []
    private var refreshPending = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // A menu bar app is usually not frontmost; ask GC to keep delivering events.
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCRacingWheelDidConnect, .GCRacingWheelDidDisconnect,
                     .GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachHandlers(); self?.refresh() }
            })
        }
        attachHandlers()
        refresh()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for wheel in GCRacingWheel.connectedRacingWheels where wheel.isAcquired { wheel.relinquishDevice() }
        started = false
        wheels = []
        controllers = []
    }

    func toggleAcquire(_ id: ObjectIdentifier) {
        guard let wheel = GCRacingWheel.connectedRacingWheels.first(where: { ObjectIdentifier($0) == id }) else { return }
        if wheel.isAcquired {
            wheel.relinquishDevice()
        } else {
            do { try wheel.acquireDevice(); lastError = nil } catch { lastError = "acquireDevice failed: \(error.localizedDescription)" }
        }
        refresh()
    }

    private func attachHandlers() {
        for wheel in GCRacingWheel.connectedRacingWheels {
            wheel.wheelInput.elementValueDidChangeHandler = { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleRefresh() } }
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    func refresh() {
        wheels = GCRacingWheel.connectedRacingWheels.map(snapshot)
        controllers = GCController.controllers().map { c in
            let profile: String =
                c.extendedGamepad != nil ? "extendedGamepad" :
                c.microGamepad != nil ? "microGamepad" : "physicalInputProfile only"
            return GCControllerSnapshot(
                id: ObjectIdentifier(c), vendorName: c.vendorName ?? "?", productCategory: c.productCategory,
                profile: profile, hasHaptics: c.haptics != nil, hasLight: c.light != nil, hasBattery: c.battery != nil)
        }
    }

    private func snapshot(_ wheel: GCRacingWheel) -> GCWheelSnapshot {
        let input = wheel.wheelInput
        var elements: [GCElementInfo] = []
        for e in input.elements {
            let name = (e.localizedName ?? e.aliases.sorted().first) ?? "?"
            let kind: String
            let value: String
            if let b = e as? GCButtonElement {
                kind = "button"
                value = String(format: "%.3f%@", b.pressedInput.value, b.pressedInput.isPressed ? " pressed" : "")
            } else if let a = e as? GCAxisElement {
                kind = "axis"
                value = a.absoluteInput.map { String(format: "%.3f", $0.value) } ?? "relative only"
            } else if let s = e as? GCGearShifterElement {
                kind = "shifter"
                value = s.patternInput.map { "gear \($0.position)" } ?? (s.sequentialInput != nil ? "sequential" : "?")
            } else if let d = e as? GCDirectionPadElement {
                kind = "dpad"
                value = String(format: "x %.2f y %.2f", d.xAxis.value, d.yAxis.value)
            } else if let sw = e as? GCSwitchElement {
                kind = "switch"
                value = "\(sw.positionInput.position)"
            } else {
                kind = String(describing: type(of: e))
                value = ""
            }
            elements.append(GCElementInfo(id: e.aliases.sorted().joined(separator: ","), kind: kind,
                                          value: "\(name): \(value)  [aliases: \(e.aliases.sorted().joined(separator: ", "))]"))
        }
        let shifter: String = {
            guard let s = input.shifter else { return "none" }
            if s.patternInput != nil { return "pattern" }
            if s.sequentialInput != nil { return "sequential" }
            return "present"
        }()
        return GCWheelSnapshot(
            id: ObjectIdentifier(wheel), vendorName: wheel.vendorName ?? "?", productCategory: wheel.productCategory,
            acquired: wheel.isAcquired, maxDegrees: input.wheel.maximumDegreesOfRotation,
            steering: input.wheel.absoluteInput?.value,
            accelerator: input.acceleratorPedal?.pressedInput.value,
            brake: input.brakePedal?.pressedInput.value,
            clutch: input.clutchPedal?.pressedInput.value,
            shifter: shifter, elements: elements.sorted { $0.id < $1.id })
    }
}
