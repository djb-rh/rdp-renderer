// The Race Drivin' Panorama link: BA <type> <body> <checksum>, one way, 38400 8N1.
// Decoded 2026-09-15 (rdp-sidepod/rdplink.py is the reference implementation).
import Foundation
import simd

public struct CarRecord: Equatable {
    public var slot: Int
    public var x: Int32, y: Int32, z: Int32
    public var pitch: Int8, roll: Int8
    public var heading: UInt8          // 256ths of a turn; forward = (sin, cos) in x,z
    public var headingRadians: Double { Double(heading) * 2 * .pi / 256 }
}

public struct Pose: Equatable {
    public var x: Int32, y: Int32, z: Int32
    public var m: [Double]             // 9 entries, row-major, unit scale (1.14 fixed / 16384)
    public var steer: Int16
    public var cars: [CarRecord]
    public var right: SIMD3<Double>   { SIMD3(m[0], m[3], m[6]) }
    public var up: SIMD3<Double>      { SIMD3(m[1], m[4], m[7]) }
    public var forward: SIMD3<Double> { SIMD3(m[2], m[5], m[8]) }
    public var position: SIMD3<Double> { SIMD3(Double(x), Double(y), Double(z)) }
}

public enum LinkPacket: Equatable {
    case roster(track: Int, models: [Int])   // type 01, 10 bytes
    case boot                                 // type 01, 4 bytes
    case pose(Pose)                           // type 02
    case key                                  // type 04
    case heartbeat                            // type 05
    case dial(Int16)                          // type 06
    case other(type: UInt8, body: [UInt8])

    public static func decode(type: UInt8, body: [UInt8]) -> LinkPacket {
        switch type {
        case 0x01 where body.count >= 3 && body.count >= 3 + Int(body[2]):
            return .roster(track: Int(body[0]), models: body[3..<3 + Int(body[2])].map { Int($0) })
        case 0x01: return .boot
        case 0x02 where body.count >= 33:
            return .pose(decodePose(body))
        case 0x04: return .key
        case 0x05: return .heartbeat
        case 0x06 where body.count >= 2:
            return .dial(Int16(bitPattern: UInt16(body[0]) << 8 | UInt16(body[1])))
        default: return .other(type: type, body: body)
        }
    }

    static func be32(_ b: ArraySlice<UInt8>) -> Int32 {
        let u = b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Int32(bitPattern: u)
    }

    static func decodePose(_ b: [UInt8]) -> Pose {
        let x = be32(b[0..<4]), y = be32(b[4..<8]), z = be32(b[8..<12])
        var m = [Double](repeating: 0, count: 9)
        for i in 0..<9 {
            let v = Int16(bitPattern: UInt16(b[12 + 2*i]) << 8 | UInt16(b[13 + 2*i]))
            m[i] = Double(v) / 16384.0
        }
        let steer = Int16(bitPattern: UInt16(b[30]) << 8 | UInt16(b[31]))
        var cars: [CarRecord] = []
        var off = 33
        while off + 11 <= b.count {
            let r = b[off..<off + 11]
            var v: UInt64 = 0
            for k in 1...7 { v = v << 8 | UInt64(r[off + k]) }
            let xr = Int32(truncatingIfNeeded: sign20(Int(v >> 36)))
            if xr != 0x7FFFD {
                let y4 = Int32((v >> 20) & 0xFFFF)
                let zr = Int32(truncatingIfNeeded: sign20(Int(v & 0xFFFFF)))
                cars.append(CarRecord(slot: Int(r[off]), x: xr, y: y4 * 4, z: zr,
                                      pitch: Int8(bitPattern: r[off + 8]), roll: Int8(bitPattern: r[off + 9]), heading: r[off + 10]))
            }
            off += 11
        }
        return Pose(x: x, y: y, z: z, m: m, steer: steer, cars: cars)
    }

    static func sign20(_ v: Int) -> Int { v & 0x80000 != 0 ? v - 0x100000 : v }
}

/// Incremental framer: a packet is accepted when its checksum matches and the next byte is the sync.
public final class LinkFramer {
    public static let sync: UInt8 = 0xBA
    public static let maxBody = 200
    private var buf: [UInt8] = []
    public private(set) var good = 0, resync = 0
    public init() {}

    /// Feed bytes; returns whole packets (sync and checksum included).
    public func feed(_ data: [UInt8]) -> [[UInt8]] {
        buf.append(contentsOf: data)
        var out: [[UInt8]] = []
        while true {
            guard let i = buf.firstIndex(of: Self.sync) else { resync += buf.count; buf.removeAll(); break }
            if i > 0 { resync += i; buf.removeFirst(i) }
            if buf.count < 4 { break }
            let t = Int(buf[1])
            var found: Int? = nil, needMore = false
            var sum = t
            for n in 1...Self.maxBody {
                let e = 2 + n
                if e + 1 >= buf.count { needMore = true; break }
                sum += Int(buf[e - 1])
                if sum & 0xFF == Int(buf[e]) && buf[e + 1] == Self.sync { found = n; break }
            }
            if let n = found {
                out.append(Array(buf[0..<3 + n])); good += 1; buf.removeFirst(3 + n); continue
            }
            if needMore { break }
            resync += 1; buf.removeFirst()
        }
        return out
    }

    public static func unpack(_ packet: [UInt8]) -> LinkPacket? {
        guard packet.count >= 3, packet[0] == sync else { return nil }
        return LinkPacket.decode(type: packet[1], body: Array(packet[2..<packet.count - 1]))
    }
}
