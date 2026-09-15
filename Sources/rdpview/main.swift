// rdpview: a wireframe of the world from the link, on the Mac.  The skeleton of the faithful renderer.
//   rdpview world.json --udp 5000 [--yaw 53] [--pitch 0]
//   rdpview world.json --replay capture.bin
import AppKit
import RDPKit
import simd

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: rdpview world.json (--udp PORT | --replay FILE) [--yaw DEG] [--pitch DEG] [--track N] [--bank B] [--cull 1|-1] [--wire] [--raw] [--sky I] [--ground I] [--light x,y,z] [--camlight] [--ambient A] [--width W --height H] [--snapshot out.png --after S | --at T]"); exit(1) }
func opt(_ name: String) -> String? { if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }; return nil }
let world = try World.load(URL(fileURLWithPath: args[1]))
var instantState: LinkState? = nil
let yaw = Double(opt("--yaw") ?? "0") ?? 0, pitch = Double(opt("--pitch") ?? "0") ?? 0
let source: LinkSource = {
    if let p = opt("--udp") { return UDPSource(port: UInt16(p) ?? 5000) }
    if let f = opt("--replay") { return try! ReplaySource(url: URL(fileURLWithPath: f)) }
    print("no source: use --udp PORT or --replay FILE"); exit(1)
}()
let receiver = LinkReceiver(source: source)
if let at = opt("--at"), let t = Double(at), let f = opt("--replay") {
    // deterministic: everything up to t, held, one frame, exit
    let ir = try! InstantReplay(url: URL(fileURLWithPath: f)); ir.feed(upTo: t); ir.state.hold = true
    instantState = ir.state
} else {
    receiver.start()
}
let defaultTrack = Int(opt("--track") ?? "3") ?? 3
print("world: tracks \(world.tracks.keys.sorted()), \(world.objects.count) objects")

let bank = Int(opt("--bank") ?? "0") ?? 0
let cullSign = Double(opt("--cull") ?? "-1") ?? -1
let wire = args.contains("--wire")
let idmap = args.contains("--idmap")
let lightArg = (opt("--light") ?? "0,1,0").split(separator: ",").compactMap { Double($0) }
var shading = Shading(); shading.light = simd_normalize(SIMD3(lightArg[0], lightArg[1], lightArg[2])); shading.cameraSpace = args.contains("--camlight"); shading.perObject = !args.contains("--facelight")
if let a = opt("--ambient"), let v = Double(a) { shading.ambient = v }
let rawColours = args.contains("--raw")
let skyIndex = Int(opt("--sky") ?? "28") ?? 28, groundIndex = Int(opt("--ground") ?? "12") ?? 12     // fill each face with its attribute (R = colour, G = attr>>8) for calibration
let viewW = Double(opt("--width") ?? "1024") ?? 1024, viewH = Double(opt("--height") ?? "384") ?? 384

var renderOptions = RenderOptions()
renderOptions.yawDegrees = yaw; renderOptions.pitchDegrees = pitch; renderOptions.bank = bank; renderOptions.cullSign = cullSign
renderOptions.wire = wire; renderOptions.idmap = idmap; renderOptions.rawColours = rawColours
renderOptions.objectKeyMode = Int(opt("--objkey") ?? "0") ?? 0; if let kv = opt("--k"), let k = Double(kv) { renderOptions.kOverride = k }
if let kv = opt("--ky"), let k = Double(kv) { renderOptions.kyOverride = k }
if let kv = opt("--cy"), let k = Double(kv) { renderOptions.cyOverride = k }
if let e = opt("--eye") { let v = e.split(separator: ",").compactMap { Double($0) }; if v.count == 3 { renderOptions.eyeOffset = SIMD3(v[0], v[1], v[2]) } }
renderOptions.fillNear = Double(opt("--fillnear") ?? "200") ?? 200; renderOptions.skyIndex = skyIndex; renderOptions.groundIndex = groundIndex; renderOptions.defaultTrack = defaultTrack; renderOptions.shading = shading
let renderer = FrameRenderer(options: renderOptions)

final class WorldView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let stats = renderer.draw(in: ctx, size: bounds.size, world: world, state: instantState ?? receiver.state)
        if snapshot == nil {
            let s = stats.pose.map { String(format: "track %d  pos %d %d %d  cars %d  faces %d  packets %d", stats.track, $0.x, $0.y, $0.z, $0.cars.count, stats.faces, receiver.state.packets) } ?? "waiting for the link... packets \(receiver.state.packets)"
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
    let wait = instantState != nil ? 0.05 : (Double(opt("--after") ?? "4") ?? 4)
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
        if let pose = receiver.state.predicted() { let cam = Camera(pose: pose, yawDegrees: renderOptions.yawDegrees, pitchDegrees: renderOptions.pitchDegrees); let hdg = (atan2(cam.forward.x, cam.forward.z) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360); print(String(format: "pose x %d y %d z %d  camera heading %.1f  pitch %.3f", pose.x, pose.y, pose.z, hdg, cam.forward.y)) }
        print("wrote \(path); packets \(receiver.state.packets)")
        exit(0)
    }
} else {
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
}
Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in view.needsDisplay = true }
app.run()
