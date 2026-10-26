// Run: ./build.sh check
import Foundation
import CoreGraphics

// Capabilities parsing, against the Dell S2725QC's real string.
let dell = "(prot(monitor)type(LCD)model(S2725QC)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 05 08 0B 0C) 16 18 1A 52 60(1B 11 12 ) 62(FF FE) 87 D6(01 04 05) DC(00 03 05 ) EA(FE FC F800 F801 ) FD)mswhql(1)mccs_ver(2.1))"
let codes = DDC.supportedCodes(dell)
assert(codes[0x60] == [0x1B, 0x11, 0x12] && codes[0xDC] == [0, 3, 5] && codes[0x14] == [1, 5, 8, 0x0B, 0x0C])
assert(codes[0x10] == [] && codes[0x8D] == nil && codes[0xEA]?.count == 4 && codes[0x03] == nil)
print("Capabilities parser OK")

// Matching IORegistry ProductAttributes to CoreGraphics displays: two identical Dells differ only by serial.
let dellA: [String: Any] = ["LegacyManufacturerID": 4268, "ProductID": 41586, "SerialNumber": 809848642, "ProductName": "DELL S2725QC"]
let dellB: [String: Any] = ["LegacyManufacturerID": 4268, "ProductID": 41586, "SerialNumber": 809848643, "ProductName": "DELL S2725QC"]
let scoreA = DDC.matchScore(dellA, vendor: 4268, model: 41586, serial: 809848642, name: "DELL S2725QC")
assert(scoreA > DDC.matchScore(dellB, vendor: 4268, model: 41586, serial: 809848642, name: "DELL S2725QC"))
assert(DDC.matchScore(dellA, vendor: 7789, model: 41586, serial: 809848642, name: nil) == 0)
assert(DDC.matchScore([:], vendor: 4268, model: 41586, serial: 0, name: nil) == 0)
print("Display matching OK")

// Key steps: 16 presses cover 0...max exactly, every press moves, and the ends clamp.
for (max, steps) in [(100, 16), (100, 64), (10, 16), (255, 16)] {
    var v = 0, seen = [0]
    for _ in 0..<steps { v = DDC.step(v, max: max, steps: steps, up: true); seen.append(v) }
    assert(v == max && (max < steps || zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }), "up \(max)/\(steps): \(seen)")
    for _ in 0..<steps { v = DDC.step(v, max: max, steps: steps, up: false) }
    assert(v == 0, "down \(max)/\(steps) ended at \(v)")
}
assert(DDC.step(100, max: 100, steps: 16, up: true) == 100 && DDC.step(0, max: 100, steps: 16, up: false) == 0)
assert(DDC.step(47, max: 100, steps: 16, up: true) == 56 && DDC.step(47, max: 100, steps: 16, up: false) == 44)
print("Key steps OK")

// Hardware: round-trip a DDC write on volume (±1, then restored).
guard let (d, attributes) = DDC.externalDisplays().first, let orig = d.read(.volume)?.current else { fatalError("no DDC display / read failed") }
var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)
let matched = ids.prefix(Int(count)).contains { id in
    CGDisplayIsBuiltin(id) == 0 && DDC.matchScore(attributes, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                                  serial: CGDisplaySerialNumber(id), name: nil) >= 3
}
assert(matched, "DDC service's IORegistry attributes didn't match any online display by vendor/model/serial")
let probe = orig > 0 ? orig - 1 : 1
d.set(.volume, probe); usleep(500_000)
let got = d.read(.volume)?.current
d.set(.volume, orig); usleep(500_000)
assert(got == probe, "wrote \(probe), read back \(String(describing: got))")
assert(d.capabilities().map(DDC.supportedCodes)?[0x10] != nil, "capabilities read failed")
print("DDC OK: volume \(orig) -> \(probe) -> \(orig), capabilities read, service matched to its display")
