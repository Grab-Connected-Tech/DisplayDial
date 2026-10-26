// Run: ./build.sh check
import Foundation

// Capabilities parsing, against the Dell S2725QC's real string.
let dell = "(prot(monitor)type(LCD)model(S2725QC)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 05 08 0B 0C) 16 18 1A 52 60(1B 11 12 ) 62(FF FE) 87 D6(01 04 05) DC(00 03 05 ) EA(FE FC F800 F801 ) FD)mswhql(1)mccs_ver(2.1))"
let codes = DDC.supportedCodes(dell)
assert(codes[0x60] == [0x1B, 0x11, 0x12] && codes[0xDC] == [0, 3, 5] && codes[0x14] == [1, 5, 8, 0x0B, 0x0C])
assert(codes[0x10] == [] && codes[0x8D] == nil && codes[0xEA]?.count == 4 && codes[0x03] == nil)
print("Capabilities parser OK")

// Hardware: round-trip a DDC write on volume (±1, then restored).
guard let d = DDC.externalDisplays().first, let orig = d.read(.volume)?.current else { fatalError("no DDC display / read failed") }
let probe = orig > 0 ? orig - 1 : 1
d.set(.volume, probe); usleep(500_000)
let got = d.read(.volume)?.current
d.set(.volume, orig); usleep(500_000)
assert(got == probe, "wrote \(probe), read back \(String(describing: got))")
assert(d.capabilities().map(DDC.supportedCodes)?[0x10] != nil, "capabilities read failed")
print("DDC OK: volume \(orig) -> \(probe) -> \(orig), capabilities read")
