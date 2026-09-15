// The world bundle written by rdp-fullscreen/export_bundle.py (format rdp-world-1).
import Foundation

public struct WorldObject: Decodable {
    public var name: String
    public var radius: Int, lod: Int, cull: Int
    public var verts: [[Int]]
    public var faces: [[Int]]          // [attr, normal index, v0, v1, ...]; colour = attr & 0xFF, type = attr >> 12
    public var normals: [[Int]]?       // 1.14 fixed, indexed by the face's normal index
    public var far: FarModel?
    public struct FarModel: Decodable { public var verts: [[Int]]; public var faces: [[Int]]; public var normals: [[Int]]? }
}

public struct Placement: Decodable {
    public var o: Int
    public var m: [Int]                // 3x3, 1.14 fixed, row-major
    public var p: [Int]
    public var bias: Int
    public var flags: Int
}

public struct HorizonSegment: Decodable { public var rows: [Int]; public var row: Int; public var origin: Double; public var sector: [Double]? }
public struct Horizon: Decodable {
    public var width: Int, rows: Int
    public var data: String                 // base64 palette indices, row-major
    public var segments: [HorizonSegment]
    public var px_per_degree: Double
    public var pitch_rows: Double
    public var pixels: [UInt8] { [UInt8](Data(base64Encoded: data) ?? Data()) }
}

public struct Track: Decodable {
    public var names: [String]
    public var placements: [Placement]
    public var palette: [[Int]]?          // the pod's bank 0 for this track
    public var horizon: Horizon?
}

public struct World: Decodable {
    public var format: String
    public var tracks: [String: Track]
    public var objects: [String: WorldObject]
    public var palette: [[[Int]]]      // banks x 256 x rgb

    public static func load(_ url: URL) throws -> World {
        try JSONDecoder().decode(World.self, from: Data(contentsOf: url))
    }
    public func object(_ id: Int) -> WorldObject? { objects[String(id)] }
    public func track(_ i: Int) -> Track? { tracks[String(i)] }
}
