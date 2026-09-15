// The original renderer's order and face types, as a CPU polygon list.
// Objects far to near by depth key (max camera z / 2 + bias), faces within an object far to near;
// type-1 faces fill from their top edge to the bottom of the view.  Backface test by screen winding.
import Foundation
import simd

public struct DrawnFace {
    public var points: [SIMD2<Double>]
    public var colour: Int
    public var attr: Int
    public var key: Double
}

/// The ADSP's colour rule (routine 0x021E): a face colour >= 31 is flat, index = colour & 0x1F;
/// a colour < 31 is lit, index = 16 + colour*16 + shade, shade = clamp((dot(normal, light) + 0.354) * 18, 0, 15).
public struct Shading {
    public var light: SIMD3<Double> = SIMD3(0, 1, 0)   // unit light direction, in the space `normalSpace` names
    public var ambient: Double = 0.354                  // 0x2D41 / 32768
    public var gain: Double = 18                        // 0x12
    public var cameraSpace = false                      // dot the normal in camera space instead of world space
    public var perObject = true                         // light from the object's up axis (rotate(0,1,0)) instead of each face's normal
    public init() {}
    /// The ADSP's integer arithmetic: MR1 = (N.L in 1.14 x 1.14, SS) >> 16 = 8192 * N.L; AR = max(0, MR1 + 0x2D41);
    /// shade = (AR * 0x12 * 2) >> 16, OR'ed into the low four bits of (colour << 4) + 16.
    public func index(colour: Int, normal: SIMD3<Double>?) -> Int {
        if colour >= 31 || normal == nil { return colour & 0x1F }
        let d = simd_dot(normal!, light)
        let ar = max(0, Int((8192.0 * d).rounded()) + 0x2D41)
        let shade = (ar * 0x12 * 2 + 0x8000) >> 16          // MR = AR * 0x12 (RND)
        return min(255, ((colour << 4) + 16) | shade)
    }
}

public struct Painter {
    public var projection: Projection
    public var cullSign: Double = 1      // +1 or -1: which winding is a back face
    public var cull = true
    public var shading: Shading? = nil   // nil: colour index = the raw attribute colour (calibration)
    public var fillNear = 200.0          // type-1 faces are skipped when any vertex is nearer than this
    public init(projection: Projection) { self.projection = projection }

    /// Faces of one model instance, projected. Faces are clipped against the near plane (z >= near) the way the
    /// ADSP does (0x027B), so a road quad that straddles the camera still draws; the other planes are left to
    /// the drawing context.
    public func faces(verts: [[Int]], faces: [[Int]], normals: [[Int]]? = nil, rotate: ((SIMD3<Double>) -> SIMD3<Double>)? = nil, transform: (SIMD3<Double>) -> SIMD3<Double>, camera: Camera, bias: Double = 0) -> [DrawnFace] {
        var cam: [SIMD3<Double>] = []; cam.reserveCapacity(verts.count)
        for v in verts { cam.append(camera.toCamera(transform(SIMD3(Double(v[0]), Double(v[1]), Double(v[2]))))) }
        var out: [DrawnFace] = []
        let near = projection.near
        for f in faces {
            guard f.count >= 5 else { continue }
            let attr = f[0], nidx = f[1], type = attr >> 12
            var colour = attr & 0xFF
            if let sh = shading {
                var n: SIMD3<Double>? = nil
                if sh.perObject {
                    var w = SIMD3<Double>(0, 1, 0); if let r = rotate { w = r(w) }
                    n = w
                } else if let ns = normals, nidx >= 0, nidx < ns.count {
                    var w = SIMD3(Double(ns[nidx][0]), Double(ns[nidx][1]), Double(ns[nidx][2])) / 16384.0
                    if let r = rotate { w = r(w) }
                    if sh.cameraSpace { w = SIMD3(simd_dot(w, camera.right), simd_dot(w, camera.up), simd_dot(w, camera.forward)) }
                    n = w
                }
                colour = sh.index(colour: colour, normal: n)
            }
            // gather camera-space vertices, then clip against z = near
            var poly: [SIMD3<Double>] = []; var ok = true; var maxz = -1e30
            for i in f.dropFirst(2) { guard i < cam.count else { ok = false; break }; poly.append(cam[i]); maxz = max(maxz, cam[i].z) }
            guard ok, poly.count >= 3, maxz >= near else { continue }
            if type == 1 && poly.contains(where: { $0.z < fillNear }) { continue }
            if poly.contains(where: { $0.z < near }) {
                var clipped: [SIMD3<Double>] = []
                for k in 0..<poly.count {
                    let a = poly[k], b = poly[(k + 1) % poly.count]
                    let ain = a.z >= near, bin = b.z >= near
                    if ain { clipped.append(a) }
                    if ain != bin { let t = (near - a.z) / (b.z - a.z); clipped.append(a + (b - a) * t) }
                }
                poly = clipped
                guard poly.count >= 3 else { continue }
            }
            var pts: [SIMD2<Double>] = []
            for c in poly { guard let p = projection.project(c) else { ok = false; break }; pts.append(p) }
            guard ok else { continue }
            if cull && type != 1 {                       // fill faces are not back-face tested
                var area = 0.0
                for k in 0..<pts.count { let a = pts[k], b = pts[(k + 1) % pts.count]; area += a.x * b.y - b.x * a.y }
                if area * cullSign > 0 { continue }
            }
            if type == 1 {
                let top = pts.min(by: { $0.y < $1.y })!.y
                let xs = pts.map { $0.x }
                pts = [SIMD2(xs.min()!, top), SIMD2(xs.max()!, top), SIMD2(xs.max()!, projection.height), SIMD2(xs.min()!, projection.height)]
            }
            out.append(DrawnFace(points: pts, colour: colour, attr: attr, key: maxz / 2 + bias))
        }
        return out
    }
}
