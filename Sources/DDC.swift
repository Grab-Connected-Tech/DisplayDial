import Foundation
import IOKit

// Private IOKit symbols used by every Apple Silicon DDC tool (MonitorControl, Lunar, m1ddc).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ addr: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn

enum VCP: UInt8, CaseIterable, Codable {
    case brightness = 0x10, contrast = 0x12, colorPreset = 0x14
    case redGain = 0x16, greenGain = 0x18, blueGain = 0x1A
    case input = 0x60, volume = 0x62, presetMode = 0xDC
}

final class DDC: @unchecked Sendable {
    private let service: CFTypeRef
    private let queue = DispatchQueue(label: "ddc")
    private let lock = NSLock()
    private var pending: [VCP: Int] = [:]

    private init(_ service: CFTypeRef) { self.service = service }

    static func externalDisplays() -> [DDC] {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var result: [DDC] = []
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            result.append(DDC(av))
        }
        return result
    }

    private func write(_ payload: [UInt8]) -> Bool {
        var packet = [0x80 | UInt8(payload.count)] + payload
        packet.append(packet.reduce(0x6E ^ 0x51, ^))
        return IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess
    }

    func read(_ code: VCP) -> (current: Int, max: Int)? {
        queue.sync {
            for _ in 0..<4 {
                guard write([0x01, code.rawValue]) else { continue }
                usleep(40_000)
                var reply = [UInt8](repeating: 0, count: 11)
                guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                      reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue,
                      reply[..<10].reduce(0x50, ^) == reply[10] else { usleep(20_000); continue }
                return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
            }
            return nil
        }
    }

    // MCCS capabilities string, e.g. "(prot(monitor)...vcp(10 12 14(01 05 08) 60(1B 11 12))...)".
    func capabilities() -> String? {
        queue.sync {
            var caps: [UInt8] = []
            while caps.count < 4096 {
                var chunk: ArraySlice<UInt8>?
                for _ in 0..<5 {
                    let off = caps.count
                    guard write([0xF3, UInt8(off >> 8 & 0xFF), UInt8(off & 0xFF)]) else { continue }
                    usleep(60_000)
                    var reply = [UInt8](repeating: 0, count: 38)
                    let ok = IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess
                    let n = Int(reply[1] & 0x7F) - 3
                    guard ok, reply[2] == 0xE3, (0...32).contains(n), Int(reply[3]) << 8 | Int(reply[4]) == off,
                          reply[..<(5 + n)].reduce(0x50, ^) == reply[5 + n] else { usleep(30_000); continue }
                    chunk = reply[5..<(5 + n)]
                    break
                }
                guard let chunk else { return nil }
                if chunk.isEmpty { break }
                caps += chunk
            }
            return String(decoding: caps, as: UTF8.self)
        }
    }

    // Supported VCP codes from a capabilities string; listed values (e.g. inputs) when the monitor gives them.
    static func supportedCodes(_ caps: String) -> [UInt8: [Int]] {
        guard let start = caps.range(of: "vcp(")?.upperBound else { return [:] }
        var result: [UInt8: [Int]] = [:]
        var last: UInt8?, depth = 0, token = ""
        func flush() {
            defer { token = "" }
            guard let v = Int(token, radix: 16) else { return }
            if depth == 0, let code = UInt8(exactly: v) { last = code; result[code] = [] }
            else if depth == 1, let last { result[last]?.append(v) }
        }
        for ch in caps[start...] {
            switch ch {
            case "(": flush(); depth += 1
            case ")": flush(); if depth == 0 { return result }; depth -= 1
            case " ": flush()
            default: token.append(ch)
            }
        }
        return result
    }

    // MCCS 0x08 "restore factory colour defaults": write-only, any non-zero value triggers it.
    func restoreFactoryColor() {
        queue.async { [self] in _ = write([0x03, 0x08, 0x00, 0x01]) }
    }

    // Slider drags fire far faster than DDC can take writes; only the latest value per code is sent.
    func set(_ code: VCP, _ value: Int) {
        lock.lock(); let alreadyQueued = pending.updateValue(value, forKey: code) != nil; lock.unlock()
        guard !alreadyQueued else { return }
        queue.async { [self] in
            lock.lock(); let latest = pending.removeValue(forKey: code); lock.unlock()
            guard let latest else { return }
            // Monitors silently drop the odd DDC write; a second copy is cheap insurance.
            for _ in 0..<2 {
                _ = write([0x03, code.rawValue, UInt8(latest >> 8 & 0xFF), UInt8(latest & 0xFF)])
                usleep(15_000)
            }
        }
    }
}
