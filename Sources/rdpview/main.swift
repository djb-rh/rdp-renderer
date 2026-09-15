// rdpview: a wireframe of the world from the link, on the Mac.  The skeleton of the faithful renderer.
//   rdpview world.json --udp 5000 [--yaw 53] [--pitch 0]
//   rdpview world.json --replay capture.bin
import AppKit
import RDPKit
import simd

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: rdpview world.json (--udp PORT | --replay FILE) [--yaw DEG] [--pitch DEG] [--track N] [--snapshot out.png --after S]"); exit(1) }
func opt(_ name: String) -> String? { if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }; return nil }
let world = try World.load(URL(fileURLWithPath: args[1]))
let yaw = Double(opt("--yaw") ?? "0") ?? 0, pitch = Double(opt("--pitch") ?? "0") ?? 0
let source: LinkSource = {
    if let p = opt("--udp") { return UDPSource(port: UInt16(p) ?? 5000) }
    if let f = opt("--replay") { return try! ReplaySource(url: URL(fileURLWithPath: f)) }
    print("no source: use --udp PORT or --replay FILE"); exit(1)
}()
let receiver = LinkReceiver(source: source)
receiver.start()
let defaultTrack = Int(opt("--track") ?? "3") ?? 3
print("world: tracks \(world.tracks.keys.sorted()), \(world.objects.count) objects")

final class WorldView: NSView {
    var frames = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        frames += 1
        guard let pose = receiver.state.predicted() else {
            let s = "waiting for the link... packets \(receiver.state.packets)"
            s.draw(at: NSPoint(x: 10, y: 10), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            return
        }
        let cam = Camera(pose: pose, yawDegrees: yaw, pitchDegrees: pitch)
        let proj = Projection.faithful(width: bounds.width, height: bounds.height)
        let pal = world.palette.first ?? []
        var drawn = 0
        func drawModel(verts: [[Int]], faces: [[Int]], m: [Int]?, heading: Double?, at p: SIMD3<Double>) {
            var pts: [SIMD2<Double>?] = []
            pts.reserveCapacity(verts.count)
            for v in verts {
                var w = SIMD3(Double(v[0]), Double(v[1]), Double(v[2]))
                if let m = m { w = rotate14(w, m: m) }
                else if let h = heading { w = SIMD3(w.x * cos(h) + w.z * sin(h), w.y, -w.x * sin(h) + w.z * cos(h)) }
                pts.append(proj.project(cam.toCamera(w + p)))
            }
            for f in faces {
                let c = f[0]
                let rgb = c < pal.count ? pal[c] : [200, 200, 200]
                NSColor(red: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1).setStroke()
                let path = NSBezierPath()
                var first = true, valid = true
                for i in f.dropFirst() {
                    guard i < pts.count, let q = pts[i] else { valid = false; break }
                    if first { path.move(to: NSPoint(x: q.x, y: q.y)); first = false } else { path.line(to: NSPoint(x: q.x, y: q.y)) }
                }
                if valid { path.close(); path.lineWidth = 1; path.stroke(); drawn += 1 }
            }
        }
        let trackIndex = receiver.state.track >= 0 ? receiver.state.track : defaultTrack
        for pl in world.track(trackIndex)?.placements ?? [] {
            guard let obj = world.object(pl.o) else { continue }
            let p = SIMD3(Double(pl.p[0]), Double(pl.p[1]), Double(pl.p[2]))
            let d = simd_length(p - cam.position)
            if obj.cull > 0 && d > Double(obj.cull) { continue }
            if d > 40000 { continue }
            let far = obj.far, useFar = far != nil && obj.lod > 0 && d > Double(obj.lod)
            drawModel(verts: useFar ? far!.verts : obj.verts, faces: useFar ? far!.faces : obj.faces, m: pl.m, heading: nil, at: p)
        }
        for car in pose.cars {
            let slot = car.slot
            guard slot < receiver.state.roster.count, let obj = world.object(receiver.state.roster[slot]) else { continue }
            drawModel(verts: obj.verts, faces: obj.faces, m: nil, heading: car.headingRadians, at: SIMD3(Double(car.x), Double(car.y), Double(car.z)))
        }
        let s = String(format: "track %d  pos %d %d %d  cars %d  faces %d  packets %d", trackIndex, pose.x, pose.y, pose.z, pose.cars.count, drawn, receiver.state.packets)
        s.draw(at: NSPoint(x: 10, y: 10), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
    }
}

let app = NSApplication.shared
let snapshot = opt("--snapshot")
app.setActivationPolicy(snapshot == nil ? .regular : .prohibited)
let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1024, height: 384), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
win.title = "rdpview"
let view = WorldView(frame: win.contentView!.bounds)
view.autoresizingMask = [.width, .height]
win.contentView?.addSubview(view)
if let path = snapshot {
    // headless: wait for the link, draw one frame into a bitmap, write PNG, exit
    let wait = Double(opt("--after") ?? "4") ?? 4
    Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path); packets \(receiver.state.packets)")
        exit(0)
    }
} else {
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
}
Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in view.needsDisplay = true }
app.run()
