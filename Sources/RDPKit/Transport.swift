// Byte sources: a UDP port (one datagram per packet from podlink.py --udp, or raw bytes), and a capture replay.
import Foundation

public protocol LinkSource { func start(_ sink: @escaping ([UInt8]) -> Void); func stop() }

public final class UDPSource: LinkSource {
    let port: UInt16
    private var fd: Int32 = -1
    private var thread: Thread?
    public init(port: UInt16) { self.port = port }

    public func start(_ sink: @escaping ([UInt8]) -> Void) {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = INADDR_ANY
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(ok == 0, "cannot bind udp port \(port)")
        let fd = self.fd
        thread = Thread {
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                sink(Array(buf[0..<n]))
            }
        }
        thread?.start()
    }
    public func stop() { if fd >= 0 { close(fd); fd = -1 } }
}

/// Replays a capture (rdp-sidepod capture/*.bin) with its .times file if present, else at line rate.
public final class ReplaySource: LinkSource {
    let bytes: [UInt8]; let times: [Double]?
    private var thread: Thread?
    public var loop = true
    public init(url: URL) throws {
        bytes = [UInt8](try Data(contentsOf: url))
        let tpath = url.path + ".times"
        if let s = try? String(contentsOfFile: tpath) {
            let t = s.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap { Double($0) }
            times = t.count == bytes.count ? t : nil
        } else { times = nil }
    }
    public func start(_ sink: @escaping ([UInt8]) -> Void) {
        let bytes = self.bytes, times = self.times, loop = self.loop
        thread = Thread {
            repeat {
                let t0 = Date().timeIntervalSinceReferenceDate, base = times?.first ?? 0
                var i = 0
                while i < bytes.count {
                    let when = times.map { $0[i] - base } ?? Double(i) * 10.0 / 38400
                    let delay = when - (Date().timeIntervalSinceReferenceDate - t0)
                    if delay > 0.0005 { Thread.sleep(forTimeInterval: delay) }
                    // send everything that is due now in one chunk
                    var j = i + 1
                    if let ts = times { while j < bytes.count && ts[j] - base <= Date().timeIntervalSinceReferenceDate - t0 { j += 1 } }
                    sink(Array(bytes[i..<j])); i = j
                }
            } while loop
        }
        thread?.start()
    }
    public func stop() { thread?.cancel() }
}

/// Wires a source through the framer into a LinkState.
public final class LinkReceiver {
    public let state = LinkState()
    private let framer = LinkFramer()
    private let source: LinkSource
    private let q = DispatchQueue(label: "rdp.link")
    public init(source: LinkSource) { self.source = source }
    public func start() {
        source.start { [self] bytes in
            q.async {
                for p in self.framer.feed(bytes) { if let pk = LinkFramer.unpack(p) { self.state.accept(pk) } }
            }
        }
    }
    public func stop() { source.stop() }
}
