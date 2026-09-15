// rdpview: a wireframe of the world from the link, on the Mac.  The skeleton of the faithful renderer.
//   rdpview world.json --udp 5000 [--yaw 53] [--pitch 0]
//   rdpview world.json --replay capture.bin
import AppKit
import RDPKit
import simd

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: rdpview world.json (--udp PORT | --replay FILE) [--yaw DEG] [--pitch DEG] [--track N] [--bank B] [--cull 1|-1] [--wire] [--raw] [--sky I] [--ground I] [--light x,y,z] [--camlight] [--ambient A] [--width W --height H] [--snapshot out.png --after S]"); exit(1) }
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

let bank = Int(opt("--bank") ?? "0") ?? 0
let cullSign = Double(opt("--cull") ?? "1") ?? 1
let wire = args.contains("--wire")
let idmap = args.contains("--idmap")
let lightArg = (opt("--light") ?? "0,1,0").split(separator: ",").compactMap { Double($0) }
var shading = Shading(); shading.light = simd_normalize(SIMD3(lightArg[0], lightArg[1], lightArg[2])); shading.cameraSpace = args.contains("--camlight")
if let a = opt("--ambient"), let v = Double(a) { shading.ambient = v }
let rawColours = args.contains("--raw")
let skyIndex = Int(opt("--sky") ?? "28") ?? 28, groundIndex = Int(opt("--ground") ?? "12") ?? 12     // fill each face with its attribute (R = colour, G = attr>>8) for calibration
let viewW = Double(opt("--width") ?? "1024") ?? 1024, viewH = Double(opt("--height") ?? "384") ?? 384

final class WorldView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.black.setFill(); bounds.fill()
        guard let pose = receiver.state.predicted() else {
            "waiting for the link... packets \(receiver.state.packets)".draw(at: NSPoint(x: 10, y: 10), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            return
        }
        let cam = Camera(pose: pose, yawDegrees: yaw, pitchDegrees: pitch)
        let proj = Projection.faithful(width: bounds.width, height: bounds.height)
        var painter = Painter(projection: proj); painter.cullSign = cullSign; painter.cull = !wire; painter.shading = (rawColours || idmap) ? nil : shading
        let pal = bank < world.palette.count ? world.palette[bank] : []
        // backdrop: sky above the horizon, ground below (the pod paints entries 28 and 12)
        if !idmap && !wire {
            func palColor(_ i: Int) -> NSColor { let c = i < pal.count ? pal[i] : [0, 0, 0]; return NSColor(deviceRed: CGFloat(c[0]) / 255, green: CGFloat(c[1]) / 255, blue: CGFloat(c[2]) / 255, alpha: 1) }
            palColor(skyIndex).setFill(); bounds.fill()
            // the horizon: far points on the camera's horizontal plane, left and right
            var fh = SIMD3(cam.forward.x, 0, cam.forward.z); var rh = SIMD3(cam.right.x, 0, cam.right.z)
            if simd_length(fh) < 1e-6 { fh = SIMD3(1, 0, 0) }; fh = simd_normalize(fh)
            if simd_length(rh) < 1e-6 { rh = SIMD3(0, 0, 1) }; rh = simd_normalize(rh)
            let far = 4.0e6
            if let l = proj.project(cam.toCamera(cam.position + fh * far - rh * far)), let r = proj.project(cam.toCamera(cam.position + fh * far + rh * far)) {
                let g = NSBezierPath(); g.move(to: NSPoint(x: l.x, y: l.y)); g.line(to: NSPoint(x: r.x, y: r.y))
                g.line(to: NSPoint(x: r.x, y: bounds.height + 4)); g.line(to: NSPoint(x: l.x, y: bounds.height + 4)); g.close()
                palColor(groundIndex).setFill(); g.fill()
            }
        }
        let trackIndex = receiver.state.track >= 0 ? receiver.state.track : defaultTrack
        // objects far to near
        struct Inst { var key: Double; var faces: [DrawnFace] }
        var insts: [Inst] = []
        for pl in world.track(trackIndex)?.placements ?? [] {
            guard let obj = world.object(pl.o) else { continue }
            let p = SIMD3(Double(pl.p[0]), Double(pl.p[1]), Double(pl.p[2]))
            let d = simd_length(p - cam.position)
            if obj.cull > 0 && d > Double(obj.cull) { continue }
            if obj.cull == 0 && d > 200000 { continue }
            let far = obj.far, useFar = far != nil && obj.lod > 0 && d > Double(obj.lod)
            let m = pl.m
            let fs = painter.faces(verts: useFar ? far!.verts : obj.verts, faces: useFar ? far!.faces : obj.faces, normals: useFar ? nil : obj.normals, rotate: { rotate14($0, m: m) }, transform: { rotate14($0, m: m) + p }, camera: cam, bias: Double(pl.bias))
            if fs.isEmpty { continue }
            insts.append(Inst(key: cam.toCamera(p).z + Double(obj.radius) - 400 + Double(pl.bias), faces: fs.sorted { $0.key > $1.key }))
        }
        for car in pose.cars {
            guard car.slot < receiver.state.roster.count, let obj = world.object(receiver.state.roster[car.slot]) else { continue }
            let p = SIMD3(Double(car.x), Double(car.y), Double(car.z)); let h = car.headingRadians
            let rot: (SIMD3<Double>) -> SIMD3<Double> = { w in SIMD3(w.x * cos(h) + w.z * sin(h), w.y, -w.x * sin(h) + w.z * cos(h)) }
            let fs = painter.faces(verts: obj.verts, faces: obj.faces, normals: obj.normals, rotate: rot, transform: { rot($0) + p }, camera: cam)
            if !fs.isEmpty { insts.append(Inst(key: cam.toCamera(p).z, faces: fs.sorted { $0.key > $1.key })) }
        }
        insts.sort { $0.key > $1.key }
        var drawn = 0
        for inst in insts {
            for f in inst.faces {
                let rgb = f.colour < pal.count ? pal[f.colour] : [200, 200, 200]
                let col = idmap ? NSColor(deviceRed: CGFloat(f.attr & 0xFF) / 255, green: CGFloat(f.attr >> 8) / 255, blue: 1, alpha: 1)
                                : NSColor(deviceRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: f.points[0].x, y: f.points[0].y))
                for q in f.points.dropFirst() { path.line(to: NSPoint(x: q.x, y: q.y)) }
                path.close()
                if wire { col.setStroke(); path.lineWidth = 1; path.stroke() } else { col.setFill(); path.fill() }
                drawn += 1
            }
        }
        if snapshot == nil {
            let s = String(format: "track %d  pos %d %d %d  cars %d  faces %d  packets %d", trackIndex, pose.x, pose.y, pose.z, pose.cars.count, drawn, receiver.state.packets)
            s.draw(at: NSPoint(x: 10, y: 10), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        }
    }
}

let app = NSApplication.shared
let snapshot = opt("--snapshot")
app.setActivationPolicy(snapshot == nil ? .regular : .prohibited)
let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: viewW, height: viewH), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
win.title = "rdpview"
let view = WorldView(frame: win.contentView!.bounds)
view.autoresizingMask = [.width, .height]
win.contentView?.addSubview(view)
if let path = snapshot {
    // headless: wait for the link, draw one frame into a bitmap, write PNG, exit
    let wait = Double(opt("--after") ?? "4") ?? 4
    Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
        // draw into a device-RGB bitmap so palette values reach the PNG unmanaged
        let W = Int(view.bounds.width), H = Int(view.bounds.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        if view.isFlipped { ctx.cgContext.translateBy(x: 0, y: CGFloat(H)); ctx.cgContext.scaleBy(x: 1, y: -1) }
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
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
