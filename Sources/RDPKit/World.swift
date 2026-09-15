// The world bundle written by rdp-fullscreen/export_bundle.py (format rdp-world-1).
import Foundation

public struct WorldObject: Decodable {
    public var name: String
    public var radius: Int, lod: Int, cull: Int
    public var verts: [[Int]]
    public var faces: [[Int]]          // [colour, v0, v1, ...]
    public var far: FarModel?
    public struct FarModel: Decodable { public var verts: [[Int]]; public var faces: [[Int]] }
}

public struct Placement: Decodable {
    public var o: Int
    public var m: [Int]                // 3x3, 1.14 fixed, row-major
    public var p: [Int]
    public var bias: Int
    public var flags: Int
}

public struct Track: Decodable {
    public var names: [String]
    public var placements: [Placement]
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
