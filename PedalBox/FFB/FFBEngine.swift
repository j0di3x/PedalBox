import Foundation
import IOKit
import IOKit.hid
import PedalBoxCore

/// Force feedback bridge: receives the steering force from the BeamNG mod over UDP
/// (127.0.0.1, `FFBPacket.port`) and plays it on a classic Logitech wheel as a constant force.
///
/// Safety: if no packet arrives for `timeout` (game paused, crashed, menu, vehicle switch), the
/// force is stopped. Stopping the engine or quitting PedalBox stops the force too.
/// Everything runs on one serial queue; the UI reads `snapshot()`.
final class FFBEngine: @unchecked Sendable {
    struct Snapshot {
        var running = false
        var wheel: String?
        var force = 0.0          // what the wheel is playing now, -1...1, after gain/assist/invert
        var kmh: Double?         // car speed the game reported
        var packets = 0          // packets received since start
        var lastPacket: Date?
        var error: String?
    }

    let queue = DispatchQueue(label: "pedalbox.ffb", qos: .userInteractive)
    private let timeout: TimeInterval = 0.3

    // settings (set on `queue`)
    private var gain = 3.0
    private var returnAmount = 0.5
    private var lastSpeed: Double?
    private var steerRate = 0.0
    private var lastSteerTime: Date?
    private var invert = false
    private var minimum = 0.0
    private var stats = Stats()
    private var lastSteer: Double?

    private var manager: IOHIDManager?
    private var wheel: IOHIDDevice?
    private var reportLength = 16
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var watchdog: DispatchSourceTimer?
    private var state = Snapshot()
    private var lastSentByte: UInt8?
    private var lastSendTime = Date.distantPast
    private var testUntil = Date.distantPast

    func snapshot() -> Snapshot { queue.sync { state } }

    func configure(gain: Double, returnAmount: Double, invert: Bool, minimum: Double) {
        queue.async {
            self.gain = min(max(gain, 0), 4); self.returnAmount = returnAmount
            self.invert = invert; self.minimum = minimum
        }
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Synchronous so the force is off before the app quits.
    func stop() {
        queue.sync { self.stopOnQueue() }
    }

    /// Short push one way, for checking the direction and that the wheel answers.
    func test(_ level: Double) {
        queue.async {
            guard self.state.running else { return }
            self.testUntil = Date().addingTimeInterval(0.35)
            self.play(level, raw: true)
        }
    }

    // MARK: - Start / stop

    private func startOnQueue() {
        guard !state.running else { return }
        state = Snapshot(running: true)
        if let err = openSocket() { state.error = err; state.running = false; return }
        openHID()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        watchdog = t
    }

    private func stopOnQueue() {
        guard state.running else { return }
        send(LG4FF.stopForce)
        watchdog?.cancel(); watchdog = nil
        readSource?.cancel(); readSource = nil   // cancel handler closes the socket
        if let m = manager {
            IOHIDManagerCancel(m)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil; wheel = nil
        lastSentByte = nil
        state.running = false; state.wheel = nil; state.force = 0
    }

    // MARK: - UDP

    private func openSocket() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return "Couldn't open a UDP socket." }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = FFBPacket.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else {
            close(fd)
            return "Port \(FFBPacket.port) is in use — is another PedalBox running?"
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        socketFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(fd) }
        src.resume()
        readSource = src
        return nil
    }

    /// Reads every queued packet and plays only the newest one.
    private func drain() {
        var buf = [UInt8](repeating: 0, count: 64)
        var newest: Double?
        while true {
            let n = recv(socketFD, &buf, buf.count, 0)
            if n <= 0 { break }
            let d = Data(buf[0..<n])
            if let v = FFBPacket.parse(d) {
                newest = v; state.packets += 1
                lastSpeed = FFBPacket.speed(d)
                if let s = FFBPacket.steering(d) { trackSteering(s) }
            }
        }
        guard let v = newest else { return }
        // a new stream (game started, car spawned, unpaused): make sure the wheel's own spring is off
        if state.lastPacket.map({ Date().timeIntervalSince($0) > 1 }) ?? true { centeringOff() }
        state.lastPacket = Date()
        if Date() < testUntil { return }
        play(v, raw: false)
        stats.add(force: v, steer: lastSteer, out: state.force)
    }

    /// Steering speed in full locks per second, lightly smoothed.
    private func trackSteering(_ s: Double) {
        let now = Date()
        if let prev = lastSteer, let t = lastSteerTime {
            let dt = now.timeIntervalSince(t)
            if dt > 0.002 && dt < 0.2 { steerRate += 0.3 * ((s - prev) / dt - steerRate) } else if dt >= 0.2 { steerRate = 0 }
        }
        lastSteer = s; lastSteerTime = now
    }

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(stats.start) >= 1 { stats.flush(); stats = Stats() }
        if now >= testUntil, let last = state.lastPacket, now.timeIntervalSince(last) > timeout, lastSentByte != 0x80 {
            play(0, raw: true)
        } else if state.lastPacket == nil, now >= testUntil, lastSentByte != nil, lastSentByte != 0x80 {
            play(0, raw: true)   // test push finished and no game is sending
        }
        // resend now and then, in case a report was dropped
        if let b = lastSentByte, b != 0x80, now.timeIntervalSince(lastSendTime) > 0.25 {
            lastSentByte = nil
            play((128 - Double(b)) / 127, raw: true)
        }
    }

    // MARK: - Output

    private func play(_ level: Double, raw: Bool) {
        var l = level
        if !raw {
            var total = l * gain
            if let s = lastSteer, let v = lastSpeed {
                total += SteeringReturn.force(steer: s, kmh: v * 3.6, rate: steerRate, amount: returnAmount)
            }
            state.kmh = lastSpeed.map { $0 * 3.6 }
            l = DeadZone.boost(invert ? -total : total, minimum: minimum)
        }
        let byte = LG4FF.forceByte(l)
        state.force = (128 - Double(byte)) / 127
        guard byte != lastSentByte else { return }
        if byte == 0x80 {
            send(LG4FF.stopForce)
        } else {
            send(LG4FF.constantForce(l))
        }
        lastSentByte = byte
        lastSendTime = Date()
    }

    private func send(_ command: [UInt8]) {
        guard let w = wheel else { return }
        let report = LG4FF.report(command, length: reportLength)
        let r = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(w, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        if r != kIOReturnSuccess { state.error = String(format: "The wheel refused a command (0x%08X).", UInt32(bitPattern: r)) }
    }

    // MARK: - HID

    private func openHID() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: logitechVendorID,
            kIOHIDPrimaryUsagePageKey: 0x01,   // interface 0: the joystick, which takes lg4ff commands
            kIOHIDPrimaryUsageKey: 0x04,
        ] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            Unmanaged<FFBEngine>.fromOpaque(ctx!).takeUnretainedValue().attached(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            Unmanaged<FFBEngine>.fromOpaque(ctx!).takeUnretainedValue().detached(device)
        }, ctx)
        IOHIDManagerSetDispatchQueue(m, queue)
        IOHIDManagerActivate(m)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if r == kIOReturnNotPermitted {
            state.error = "Allow PedalBox in System Settings › Privacy & Security › Input Monitoring."
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        manager = m
    }

    private func attached(_ device: IOHIDDevice) {
        func prop(_ k: String) -> Int? { IOHIDDeviceGetProperty(device, k as CFString) as? Int }
        guard wheel == nil,
              let id = DeviceTable.identify(vendorID: prop(kIOHIDVendorIDKey) ?? 0,
                                            productID: prop(kIOHIDProductIDKey) ?? 0,
                                            bcdDevice: prop(kIOHIDVersionNumberKey)),
              id.compatibilityMode == nil,
              DeviceTable.info(for: id.model).family == .lg4ff else { return }
        wheel = device
        reportLength = max(prop(kIOHIDMaxOutputReportSizeKey) ?? 16, LG4FF.commandLength)
        state.wheel = DeviceTable.info(for: id.model).name
        state.error = nil
        lastSentByte = nil
        centeringOff()
        send(LG4FF.stopForce)
        lastSentByte = 0x80
    }

    private func centeringOff() {
        send(LG4FF.autocenterZero)
        send(LG4FF.autocenterOff)
    }

    private func detached(_ device: IOHIDDevice) {
        guard device == wheel else { return }
        wheel = nil; state.wheel = nil; lastSentByte = nil
    }
}

/// Once a second while the game sends, one line to ~/Library/Logs/PedalBox/ffb.log:
/// how strong the game's force is and whether it pushes towards the centre (it should).
private struct Stats {
    let start = Date()
    var n = 0, sumAbs = 0.0, maxAbs = 0.0, outMax = 0.0
    var toCentre = 0, awayFromCentre = 0, steerMax = 0.0

    mutating func add(force: Double, steer: Double?, out: Double) {
        n += 1; sumAbs += abs(force); maxAbs = max(maxAbs, abs(force)); outMax = max(outMax, abs(out))
        if let s = steer {
            steerMax = max(steerMax, abs(s))
            if abs(s) > 0.05 && abs(force) > 0.005 { if force * s < 0 { toCentre += 1 } else { awayFromCentre += 1 } }
        }
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PedalBox/ffb.log")

    func flush() {
        guard n > 0 else { return }
        let line = String(format: "%@ n=%d game|avg|=%.3f game|max|=%.3f wheel|max|=%.3f steer|max|=%.2f toCentre=%d away=%d\n",
                          ISO8601DateFormatter().string(from: start), n, sumAbs / Double(n), maxAbs, outMax, steerMax, toCentre, awayFromCentre)
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: Self.url.path))?[.size] as? Int, size > 2_000_000 { try? fm.removeItem(at: Self.url) }
        if let h = try? FileHandle(forWritingTo: Self.url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: Self.url) }
    }
}
