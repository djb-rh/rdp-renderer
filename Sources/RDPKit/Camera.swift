// Camera math: the pod's view from a link pose, and the original projection.
import Foundation
import simd

public struct Camera {
    public var position: SIMD3<Double>
    public var right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>

    /// The pod's camera for a pose (measured 2026-09-15): position unchanged; the car's axes
    /// rotated in its own frame, yaw about up (+53 = "RIGHT DISPLAY", toward right), then pitch about right (+ looks up).
    public init(pose: Pose, yawDegrees: Double = 0, pitchDegrees: Double = 0) {
        var r = pose.right, u = pose.up, f = pose.forward
        let a = yawDegrees * .pi / 180, b = pitchDegrees * .pi / 180
        (f, r) = (cos(a) * f + sin(a) * r, cos(a) * r - sin(a) * f)
        (f, u) = (cos(b) * f + sin(b) * u, cos(b) * u - sin(b) * f)
        position = pose.position; right = r; up = u; forward = f
    }

    public init(position: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>, forward: SIMD3<Double>) {
        self.position = position; self.right = right; self.up = up; self.forward = forward
    }

    /// World point -> camera space (x right, y up, z forward).
    public func toCamera(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - position
        return SIMD3(simd_dot(d, right), simd_dot(d, up), simd_dot(d, forward))
    }
}

/// The ADSP's projection: x' = 255 + x*k/z, y' = 255 - y*k/z, k = 508, near clip z >= 100, into a 512x512 space.
/// The pod's 68010 rasterises that into a 512x384 drawing space (rows scaled by 3/4, so ky = 381) and the
/// screen shows the middle 192 rows (96..287), which puts the projection centre at visible row 96.
public struct Projection {
    public var width: Double, height: Double, k: Double, near: Double
    /// vertical scale and centre row; nil = same k as horizontal, centre = height/2
    public var ky: Double? = nil, cy: Double? = nil
    public init(width: Double = 512, height: Double = 192, k: Double = 508, near: Double = 100) {
        self.width = width; self.height = height; self.k = k; self.near = near
    }
    public static func faithful(width: Double, height: Double) -> Projection {
        // keep the original horizontal field of view whatever the pixel size
        var p = Projection(width: width, height: height, k: 508 * width / 512, near: 100)
        p.ky = 508 * 0.75 * height / 192
        return p
    }
    public func project(_ c: SIMD3<Double>) -> SIMD2<Double>? {
        guard c.z >= near else { return nil }
        return SIMD2(width / 2 + c.x * k / c.z, (cy ?? height / 2) - c.y * (ky ?? k) / c.z)
    }
}

public func rotate14(_ v: SIMD3<Double>, m: [Int]) -> SIMD3<Double> {
    let s = 1.0 / 16384.0
    return SIMD3(Double(m[0]) * v.x + Double(m[1]) * v.y + Double(m[2]) * v.z,
                 Double(m[3]) * v.x + Double(m[4]) * v.y + Double(m[5]) * v.z,
                 Double(m[6]) * v.x + Double(m[7]) * v.y + Double(m[8]) * v.z) * s
}
