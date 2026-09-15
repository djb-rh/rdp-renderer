// The faithful software renderer, shared by every shell: draws one frame into a CoreGraphics context
// (top-left origin) from the link state and the world bundle.
import Foundation
import CoreGraphics
import simd

public struct RenderOptions {
    public var yawDegrees: Double = 0, pitchDegrees: Double = 0
    public var bank = 0
    public var cullSign: Double = -1
    public var wire = false, idmap = false, rawColours = false
    public var skyIndex = 28, groundIndex = 12
    public var defaultTrack = 3
    public var shading = Shading()
    public var maxDistance = 200000.0
    public var objectKeyMode = 0        // 0: z + radius - 400 + bias, 1: z + bias, 2: max face key, 3: z - 400 + bias
    public init() {}
}

public struct RenderStats {
    public var track = -1, faces = 0, cars = 0
    public var pose: Pose?
}

/// The horizon sheet as an RGB image in the track's palette, built once per (world, track).
public final class HorizonImage {
    public let image: CGImage
    public let horizon: Horizon
    public init?(horizon: Horizon, palette: [[Int]]) {
        self.horizon = horizon
        let px = horizon.pixels; let w = horizon.width, h = horizon.rows
        guard px.count >= w * h, w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let c = Int(px[i]); let rgb = c < palette.count ? palette[c] : [0, 0, 0]
            rgba[i*4] = UInt8(rgb[0]); rgba[i*4+1] = UInt8(rgb[1]); rgba[i*4+2] = UInt8(rgb[2])
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        image = img
    }
}

public struct FrameRenderer {
    public var options = RenderOptions()
    public var horizonCache: [Int: HorizonImage] = [:]
    public init(options: RenderOptions = RenderOptions()) { self.options = options }

    @discardableResult
    public func draw(in ctx: CGContext, size: CGSize, world: World, state: LinkState) -> RenderStats {
        var stats = RenderStats()
        let o = options
        ctx.setShouldAntialias(false)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(origin: .zero, size: size))
        guard let pose = state.predicted() else { return stats }
        stats.pose = pose
        let cam = Camera(pose: pose, yawDegrees: o.yawDegrees, pitchDegrees: o.pitchDegrees)
        let proj = Projection.faithful(width: size.width, height: size.height)
        var painter = Painter(projection: proj); painter.cullSign = o.cullSign; painter.cull = !o.wire
        painter.shading = (o.rawColours || o.idmap) ? nil : o.shading
        let trackIndex = state.track >= 0 ? state.track : o.defaultTrack
        let track = world.track(trackIndex)
        let pal = track?.palette ?? (o.bank < world.palette.count ? world.palette[o.bank] : [])
        func setColour(_ i: Int, stroke: Bool) {
            let c = i < pal.count ? pal[i] : [200, 200, 200]
            let r = CGFloat(c[0]) / 255, g = CGFloat(c[1]) / 255, b = CGFloat(c[2]) / 255
            if stroke { ctx.setStrokeColor(red: r, green: g, blue: b, alpha: 1) } else { ctx.setFillColor(red: r, green: g, blue: b, alpha: 1) }
        }
        // backdrop: sky above the horizon, ground below
        if !o.idmap && !o.wire {
            setColour(o.skyIndex, stroke: false); ctx.fill(CGRect(origin: .zero, size: size))
            var fh = SIMD3(cam.forward.x, 0, cam.forward.z); var rh = SIMD3(cam.right.x, 0, cam.right.z)
            fh = simd_length(fh) < 1e-6 ? SIMD3(1, 0, 0) : simd_normalize(fh)
            rh = simd_length(rh) < 1e-6 ? SIMD3(0, 0, 1) : simd_normalize(rh)
            let far = 4.0e6
            if let l = proj.project(cam.toCamera(cam.position + fh * far - rh * far)), let r = proj.project(cam.toCamera(cam.position + fh * far + rh * far)) {
                ctx.beginPath(); ctx.move(to: CGPoint(x: l.x, y: l.y)); ctx.addLine(to: CGPoint(x: r.x, y: r.y))
                ctx.addLine(to: CGPoint(x: r.x, y: size.height + 4)); ctx.addLine(to: CGPoint(x: l.x, y: size.height + 4)); ctx.closePath()
                setColour(o.groundIndex, stroke: false); ctx.fillPath()
            }
        }
        stats.track = trackIndex
        // the horizon: seven 512-px segments of the sheet around the compass, scrolled by heading, lifted by pitch
        if !o.idmap && !o.wire, let hz = track?.horizon {
            var hi = horizonCache[trackIndex]
            if hi == nil, let built = HorizonImage(horizon: hz, palette: pal) { hi = built }
            if let hi = hi {
                let headingDeg = (atan2(cam.forward.z, cam.forward.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                let scale = size.width / 512.0
                let pitchRows = (cam.forward.y * hz.pitch_rows).rounded()
                ctx.saveGState(); ctx.interpolationQuality = .none
                for seg in hz.segments {
                    if let sec = seg.sector, sec.count == 2 {
                        let a = sec[0], b = sec[1]
                        let inside = a <= b ? (headingDeg >= a && headingDeg <= b) : (headingDeg >= a || headingDeg <= b)
                        if !inside { continue }
                    }
                    let h = seg.rows[1] - seg.rows[0] + 1
                    var dx = ((headingDeg - seg.origin) * hz.px_per_degree).rounded().truncatingRemainder(dividingBy: 512)
                    if dx > 0 { dx -= 512 }              // the strip is cyclic: draw it at dx and dx + 512 to cover the width
                    guard let strip = hi.image.cropping(to: CGRect(x: 0, y: seg.rows[0], width: 512, height: h)) else { continue }
                    let y = (Double(seg.row) + pitchRows) * (size.height / 192.0)
                    for x in [dx, dx + 512] where x < 512 && x + 512 > 0 {
                        // CG draws images bottom-up: flip locally so the strip keeps its orientation in this top-left context
                        let r = CGRect(x: x * scale, y: y, width: 512 * scale, height: Double(h) * (size.height / 192.0))
                        ctx.saveGState(); ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
                        ctx.draw(strip, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height)); ctx.restoreGState()
                    }
                }
                ctx.restoreGState()
            }
        }
        struct Inst { var key: Double; var faces: [DrawnFace] }
        var insts: [Inst] = []
        for pl in world.track(trackIndex)?.placements ?? [] {
            guard let obj = world.object(pl.o) else { continue }
            let p = SIMD3(Double(pl.p[0]), Double(pl.p[1]), Double(pl.p[2]))
            let d = simd_length(p - cam.position)
            if obj.cull > 0 && d > Double(obj.cull) { continue }
            if obj.cull == 0 && d > o.maxDistance { continue }
            let far = obj.far, useFar = far != nil && obj.lod > 0 && d > Double(obj.lod)
            let m = pl.m
            let fs = painter.faces(verts: useFar ? far!.verts : obj.verts, faces: useFar ? far!.faces : obj.faces, normals: useFar ? far!.normals : obj.normals,
                                   rotate: { rotate14($0, m: m) }, transform: { rotate14($0, m: m) + p }, camera: cam, bias: Double(pl.bias))
            if fs.isEmpty { continue }
            let cz = cam.toCamera(p).z
            let key: Double = o.objectKeyMode == 1 ? cz + Double(pl.bias) : o.objectKeyMode == 2 ? (fs.map { $0.key }.max() ?? cz) : o.objectKeyMode == 3 ? cz - 400 + Double(pl.bias) : cz + Double(obj.radius) - 400 + Double(pl.bias)
            insts.append(Inst(key: key, faces: fs.sorted { $0.key > $1.key }))
        }
        for car in pose.cars {
            guard car.slot < state.roster.count, let obj = world.object(state.roster[car.slot]) else { continue }
            let p = SIMD3(Double(car.x), Double(car.y), Double(car.z)); let h = car.headingRadians
            let rot: (SIMD3<Double>) -> SIMD3<Double> = { w in SIMD3(w.x * cos(h) + w.z * sin(h), w.y, -w.x * sin(h) + w.z * cos(h)) }
            let fs = painter.faces(verts: obj.verts, faces: obj.faces, normals: obj.normals, rotate: rot, transform: { rot($0) + p }, camera: cam)
            if !fs.isEmpty { insts.append(Inst(key: cam.toCamera(p).z, faces: fs.sorted { $0.key > $1.key })); stats.cars += 1 }
        }
        insts.sort { $0.key > $1.key }
        ctx.setLineWidth(1)
        for inst in insts {
            for f in inst.faces {
                if o.idmap { ctx.setFillColor(red: CGFloat(f.attr & 0xFF) / 255, green: CGFloat(f.attr >> 8) / 255, blue: 1, alpha: 1) }
                else { setColour(f.colour, stroke: o.wire) }
                ctx.beginPath(); ctx.move(to: CGPoint(x: f.points[0].x, y: f.points[0].y))
                for q in f.points.dropFirst() { ctx.addLine(to: CGPoint(x: q.x, y: q.y)) }
                ctx.closePath()
                if o.wire { ctx.strokePath() } else { ctx.fillPath() }
                stats.faces += 1
            }
        }
        return stats
    }
}
