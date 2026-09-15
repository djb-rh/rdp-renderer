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
    public init() {}
}

public struct RenderStats {
    public var track = -1, faces = 0, cars = 0
    public var pose: Pose?
}

public struct FrameRenderer {
    public var options = RenderOptions()
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
        let pal = o.bank < world.palette.count ? world.palette[o.bank] : []
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
        let trackIndex = state.track >= 0 ? state.track : o.defaultTrack
        stats.track = trackIndex
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
            let fs = painter.faces(verts: useFar ? far!.verts : obj.verts, faces: useFar ? far!.faces : obj.faces, normals: useFar ? nil : obj.normals,
                                   rotate: { rotate14($0, m: m) }, transform: { rotate14($0, m: m) + p }, camera: cam, bias: Double(pl.bias))
            if fs.isEmpty { continue }
            insts.append(Inst(key: cam.toCamera(p).z + Double(obj.radius) - 400 + Double(pl.bias), faces: fs.sorted { $0.key > $1.key }))
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
