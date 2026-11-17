import Foundation
import Testing
@testable import PedalBoxCore

@Suite struct LG4FFTests {
    @Test func constantForceBytes() {
        #expect(LG4FF.constantForce(0) == [0x11, 0x08, 0x80, 0x80, 0, 0, 0])
        #expect(LG4FF.forceByte(1) == 0x01)    // + = right; bytes above 0x80 push left on a G29
        #expect(LG4FF.forceByte(-1) == 0xFF)
        #expect(LG4FF.forceByte(5) == 0x01)
        #expect(LG4FF.forceByte(.nan) == 0x80)
    }

    @Test func padsToReportLength() {
        let r = LG4FF.report(LG4FF.stopForce, length: 16)
        #expect(r.count == 16)
        #expect(r.prefix(7) == LG4FF.stopForce[...])
        #expect(r.dropFirst(7).allSatisfy { $0 == 0 })
        #expect(LG4FF.report(LG4FF.stopForce, length: 3).count == 7)
    }

    @Test func parsesPackets() {
        #expect(FFBPacket.parse(Data("PBF1 0.2500".utf8)) == 0.25)
        #expect(FFBPacket.parse(Data("PBF1 -3".utf8)) == -1)
        #expect(FFBPacket.parse(Data("PBF1 nan".utf8)) == nil)
        #expect(FFBPacket.parse(Data("HELLO 1".utf8)) == nil)
        #expect(FFBPacket.parse(Data("PBF1".utf8)) == nil)
        #expect(FFBPacket.parse(Data("PBF1 0.5 -0.2".utf8)) == 0.5)
        #expect(FFBPacket.steering(Data("PBF1 0.5 -0.2".utf8)) == -0.2)
        #expect(FFBPacket.steering(Data("PBF1 0.5".utf8)) == nil)
        #expect(FFBPacket.speed(Data("PBF1 0.5 -0.2 13.9".utf8)) == 13.9)
        #expect(FFBPacket.parse(Data("PBF1 0.5 -0.2 13.9".utf8)) == 0.5)
    }

    @Test func returnAssist() {
        #expect(SteeringReturn.force(steer: 0.5, kmh: 0, rate: 0, amount: 1) == 0)        // parked: nothing
        #expect(SteeringReturn.force(steer: 0.5, kmh: 30, rate: 0, amount: 1) < 0)       // turned right → push left
        #expect(SteeringReturn.force(steer: -0.5, kmh: 30, rate: 0, amount: 1) > 0)
        #expect(SteeringReturn.force(steer: 0.5, kmh: 30, rate: 0, amount: 0) == 0)
        #expect(SteeringReturn.speedGain(kmh: 10) == 1)
        #expect(SteeringReturn.speedGain(kmh: 6) == 0.5)
        #expect(abs(SteeringReturn.speedGain(kmh: 200) - 0.3) < 1e-9)
        // springing back to the left (rate < 0) is slowed by damping
        #expect(SteeringReturn.force(steer: 0.3, kmh: 30, rate: -2, amount: 1) > SteeringReturn.force(steer: 0.3, kmh: 30, rate: 0, amount: 1))
    }

    @Test func deadZoneBoost() {
        #expect(DeadZone.boost(0, minimum: 0.1) == 0)
        #expect(DeadZone.boost(0.3, minimum: 0) == 0.3)
        #expect(abs(DeadZone.boost(0.5, minimum: 0.1) - 0.55) < 1e-9)
        #expect(abs(DeadZone.boost(-0.5, minimum: 0.1) + 0.55) < 1e-9)
        #expect(DeadZone.boost(1, minimum: 0.1) == 1)
        #expect(DeadZone.boost(0.01, minimum: 0.1) < DeadZone.boost(0.02, minimum: 0.1))
        #expect(abs(DeadZone.boost(0.02, minimum: 0.1) - (0.1 + 0.02 * 0.9)) < 1e-9)
    }
}
