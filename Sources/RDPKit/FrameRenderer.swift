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
    public var fillNear = 200.0
    public var kOverride: Double? = nil      // projection constant for a 512-wide view (default 508)
    public var lodMode = 0                  // 0 = the catalogue's LOD distance, 1 = always the near model, 2 = always the far model
    public var horizonSectors = false      // gate strips by the fitted heading sectors (legacy; the 3584-px wrap makes it unnecessary)
    public var kyOverride: Double? = nil     // vertical projection constant for a 192-tall view (default = k)
    public var cyOverride: Double? = nil     // centre row for a 192-tall view (default 96)
    public var eyeOffset = SIMD3<Double>(0, 0, 0)   // added to the camera position in the car frame (right, up, forward)
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
    public let strips: [CGImage]            // one 512 x height image per panorama strip (empty for legacy bundles)
    static func rgbaImage(_ px: ArraySlice<UInt8>, width w: Int, height h: Int, palette: [[Int]]) -> CGImage? {
        guard px.count >= w * h, w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        var i = 0
        for c in px.prefix(w * h) {
            let rgb = Int(c) < palette.count ? palette[Int(c)] : [0, 0, 0]
            rgba[i*4] = UInt8(rgb[0]); rgba[i*4+1] = UInt8(rgb[1]); rgba[i*4+2] = UInt8(rgb[2]); i += 1
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    public init?(horizon: Horizon, palette: [[Int]]) {
        self.horizon = horizon
        let px = horizon.pixels; let w = horizon.width, h = horizon.rows
        guard let img = HorizonImage.rgbaImage(px[...], width: w, height: h, palette: palette) else { return nil }
        image = img
        var strips: [CGImage] = []
        for st in horizon.strips ?? [] {
            guard st.offset >= 0, st.offset + 512 * st.height <= px.count,
                  let si = HorizonImage.rgbaImage(px[st.offset..<(st.offset + 512 * st.height)], width: 512, height: st.height, palette: palette) else { strips = []; break }
            strips.append(si)
        }
        self.strips = strips
    }
}

/// The pod's horizon, as its GSP program computes it (rdp-fullscreen NOTES.md "How the pod really draws the horizon").
/// Rows are in the pod's 384-row drawing space; the visible view is rows 96..287.
public struct PodHorizon {
    public var rowL: Int, rowR: Int, centre: Int   // horizon row at screen x = 0, x = 512, and the centre
    public var panX: Int                           // panorama offset 0..3583: strip i's left edge sits at panX - 512*i
    /// nil when the pod would draw no horizon (looking too far up/down, or rolled past 45 degrees)
    public init?(right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>) {
        let M = 16384.0
        let m0 = Int((right.x * M).rounded()), m6 = Int((right.z * M).rounded())
        let m1 = Int((up.x * M).rounded()), m7 = Int((up.z * M).rounded())
        let m2 = Int((forward.x * M).rounded()), m8 = Int((forward.z * M).rounded())
        guard m6 != 0 || m8 != 0 else { return nil }
        let n = (m8 * m8 + m2 * m2) >> 14
        guard n >= 0x2000 else { return nil }
        // the two horizon directions 45 degrees either side of forward, projected (8192 = tan 1)
        let l60 = (m2 * n) >> 14, l80 = (m8 * n) >> 14
        let lC0 = ((m8 - l60) * m7 + (m2 + l80) * m1) >> 14
        let lA0 = ((m8 - l60) * m6 + (m2 + l80) * m0) >> 14
        let l100 = ((m8 + l60) * m7 + (m2 - l80) * m1) >> 14
        let lE0 = ((m8 + l60) * m6 + (m2 - l80) * m0) >> 14
        let y1 = (lC0 << 13) / n, x1 = (lA0 << 13) / n, y2 = (l100 << 13) / n, x2 = (lE0 << 13) / n
        let dx = x1 - x2
        guard dx >= 0x190 else { return nil }
        let l50 = (y1 + y2) >> 5
        let slope = ((y1 - y2) << 8) / dx
        let l70 = l50 + slope - 2, l60b = l50 - slope - 2
        func row(_ v: Int) -> Int { 0xC0 - (((v >> 1) + v) >> 1) }     // 192 - 0.75 v
        centre = row(l50); rowL = row(l60b); rowR = row(l70)
        guard up.y >= 0, abs(rowR - rowL) <= 256 else { return nil }
        // heading as a 16-bit turn, atan2(forward.x, forward.z); panorama offset = 3584 * (1 - heading/turn)
        let angle = Int((atan2(Double(m2), Double(m8)) * 65536 / (2 * Double.pi)).rounded())
        panX = (0x380 * ((-angle) & 0xFFFF)) >> 14
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
        var cam = Camera(pose: pose, yawDegrees: o.yawDegrees, pitchDegrees: o.pitchDegrees)
        cam.position += pose.right * o.eyeOffset.x + pose.up * o.eyeOffset.y + pose.forward * o.eyeOffset.z
        var proj = Projection.faithful(width: size.width, height: size.height)
        if let k = o.kOverride { proj.k = k * size.width / 512 }
        if let ky = o.kyOverride { proj.ky = ky * size.height / 192 }
        if let cy = o.cyOverride { proj.cy = cy * size.height / 192 }
        var painter = Painter(projection: proj); painter.cullSign = o.cullSign; painter.cull = !o.wire
        painter.shading = (o.rawColours || o.idmap) ? nil : o.shading
        painter.fillNear = o.fillNear
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
        // the horizon
        if !o.idmap && !o.wire, let hz = track?.horizon {
            var hi = horizonCache[trackIndex]
            if hi == nil, let built = HorizonImage(horizon: hz, palette: pal) { hi = built }
            if let hi = hi, !hi.strips.isEmpty, let ph = PodHorizon(right: cam.right, up: cam.up, forward: cam.forward) {
                // the pod's way: two adjacent strips of the 3584-px panorama, each blitted in vertical slices that step
                // one row per slice so the strip follows the rolled horizon line from rowL (x = 0) to rowR (x = 512)
                let sx = size.width / 512.0, sy = size.height / 192.0
                ctx.saveGState(); ctx.interpolationQuality = .none
                let i = ph.panX / 512
                for (s, xs) in [(i, ph.panX - 512 * i), ((i + 1) % 7, ph.panX - 512 * (i + 1))] {
                    guard s < hi.strips.count, s < (hz.strips?.count ?? 0) else { continue }
                    let img = hi.strips[s]; let h = hz.strips![s].height
                    let rowdiff = ph.rowR - ph.rowL
                    let count = abs(rowdiff) + 1, ystep = rowdiff < 0 ? -1 : 1
                    let xstep = (512 << 16) / count
                    var xacc = (xs << 16) + 0x8000, x0 = xs, col = 0
                    var y16 = ((ph.rowL - h) << 16) + xs * rowdiff * 128
                    for _ in 0..<count {
                        xacc += xstep
                        let x1 = xacc >> 16
                        let w = x1 - x0
                        if x1 >= 0 && x0 <= 0x1FF && w > 0, let part = img.cropping(to: CGRect(x: col, y: 0, width: w, height: h)) {
                            let y = Double((y16 >> 16) - 96)
                            let r = CGRect(x: Double(x0) * sx, y: y * sy, width: Double(w) * sx, height: Double(h) * sy)
                            ctx.saveGState(); ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
                            ctx.draw(part, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height)); ctx.restoreGState()
                        }
                        col += w; y16 += ystep << 16; x0 = x1
                    }
                }
                ctx.restoreGState()
            } else if let hi = hi {
                // legacy bundles: seven fitted angular segments of the sheet, scrolled by heading, lifted by pitch
                let headingDeg = (atan2(cam.forward.z, cam.forward.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                let scale = size.width / 512.0
                let pitchRows = (cam.forward.y * hz.pitch_rows).rounded()
                ctx.saveGState(); ctx.interpolationQuality = .none
                for seg in hz.segments {
                    if o.horizonSectors, let sec = seg.sector, sec.count == 2 {
                        let a = sec[0], b = sec[1]
                        let inside = a <= b ? (headingDeg >= a && headingDeg <= b) : (headingDeg >= a || headingDeg <= b)
                        if !inside { continue }
                    }
                    let h = seg.rows[1] - seg.rows[0] + 1
                    let turn = 360.0 * hz.px_per_degree
                    var dx = ((headingDeg - seg.origin) * hz.px_per_degree).rounded().truncatingRemainder(dividingBy: turn)
                    if dx >= turn / 2 { dx -= turn } else if dx < -turn / 2 { dx += turn }
                    if dx >= 512 || dx <= -512 { continue }
                    guard let strip = hi.image.cropping(to: CGRect(x: 0, y: seg.rows[0], width: 512, height: h)) else { continue }
                    let y = (Double(seg.row) + pitchRows) * (size.height / 192.0)
                    let r = CGRect(x: dx * scale, y: y, width: 512 * scale, height: Double(h) * (size.height / 192.0))
                    ctx.saveGState(); ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(strip, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height)); ctx.restoreGState()
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
            let far = obj.far, useFar = far != nil && (o.lodMode == 2 || (o.lodMode == 0 && obj.lod > 0 && d > Double(obj.lod)))
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
