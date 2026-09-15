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
    public init() {}
    /// The ADSP's integer arithmetic: MR1 = (N.L in 1.14 x 1.14, SS) >> 16 = 8192 * N.L; AR = max(0, MR1 + 0x2D41);
    /// shade = (AR * 0x12 * 2) >> 16, OR'ed into the low four bits of (colour << 4) + 16.
    public func index(colour: Int, normal: SIMD3<Double>?) -> Int {
        if colour >= 31 || normal == nil { return colour & 0x1F }
        let d = simd_dot(normal!, light)
        let ar = max(0, Int((8192.0 * d).rounded()) + 0x2D41)
        let shade = (ar * 0x12 * 2) >> 16
        return min(255, ((colour << 4) + 16) | shade)
    }
}

public struct Painter {
    public var projection: Projection
    public var cullSign: Double = 1      // +1 or -1: which winding is a back face
    public var cull = true
    public var shading: Shading? = nil   // nil: colour index = the raw attribute colour (calibration)
    public init(projection: Projection) { self.projection = projection }

    /// Faces of one model instance, projected; nil points (behind the near plane) drop the face.
    public func faces(verts: [[Int]], faces: [[Int]], normals: [[Int]]? = nil, rotate: ((SIMD3<Double>) -> SIMD3<Double>)? = nil, transform: (SIMD3<Double>) -> SIMD3<Double>, camera: Camera, bias: Double = 0) -> [DrawnFace] {
        var cam: [SIMD3<Double>] = []; cam.reserveCapacity(verts.count)
        for v in verts { cam.append(camera.toCamera(transform(SIMD3(Double(v[0]), Double(v[1]), Double(v[2]))))) }
        var out: [DrawnFace] = []
        for (fi, f) in faces.enumerated() {
            let attr = f[0], type = attr >> 12
            var colour = attr & 0xFF
            if let sh = shading {
                var n: SIMD3<Double>? = nil
                if let ns = normals, fi < ns.count {
                    var w = SIMD3(Double(ns[fi][0]), Double(ns[fi][1]), Double(ns[fi][2])) / 16384.0
                    if let r = rotate { w = r(w) }
                    if sh.cameraSpace { w = SIMD3(simd_dot(w, camera.right), simd_dot(w, camera.up), simd_dot(w, camera.forward)) }
                    n = w
                }
                colour = sh.index(colour: colour, normal: n)
            }
            var pts: [SIMD2<Double>] = []; var maxz = -1e30; var ok = true
            for i in f.dropFirst() {
                guard i < cam.count else { ok = false; break }
                let c = cam[i]; maxz = max(maxz, c.z)
                if type == 1 && c.z < 200 { ok = false; break }
                guard let p = projection.project(c) else { ok = false; break }
                pts.append(p)
            }
            guard ok, pts.count >= 3 else { continue }
            if cull {
                var area = 0.0
                for k in 0..<pts.count { let a = pts[k], b = pts[(k + 1) % pts.count]; area += a.x * b.y - b.x * a.y }
                if area * cullSign > 0 { continue }
            }
            if type == 1 {
                // fill to the bottom from the face's top edge: keep the two extreme x's at their top y
                let top = pts.min(by: { $0.y < $1.y })!.y
                let xs = pts.map { $0.x }
                pts = [SIMD2(xs.min()!, top), SIMD2(xs.max()!, top), SIMD2(xs.max()!, projection.height), SIMD2(xs.min()!, projection.height)]
            }
            out.append(DrawnFace(points: pts, colour: colour, attr: attr, key: maxz / 2 + bias))
        }
        return out
    }
}
