import Foundation

/// A slippy-map tile address (Web Mercator, XYZ scheme).
public struct Tile: Hashable, Sendable {
    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }
}

public enum TileMath {
    public static func tile(latitude: Double, longitude: Double, zoom: Int) -> Tile {
        let n = Double(1 << zoom)
        let x = Int(floor((longitude + 180) / 360 * n))
        let latRad = latitude * .pi / 180
        let y = Int(floor((1 - asinh(tan(latRad)) / .pi) / 2 * n))
        let limit = (1 << zoom) - 1
        return Tile(z: zoom, x: min(max(x, 0), limit), y: min(max(y, 0), limit))
    }

    /// Geographic bounds of a tile: (south, west, north, east).
    public static func bounds(of tile: Tile) -> (south: Double, west: Double, north: Double, east: Double) {
        let n = Double(1 << tile.z)
        let west = Double(tile.x) / n * 360 - 180
        let east = Double(tile.x + 1) / n * 360 - 180
        let north = atan(sinh(.pi * (1 - 2 * Double(tile.y) / n))) * 180 / .pi
        let south = atan(sinh(.pi * (1 - 2 * Double(tile.y + 1) / n))) * 180 / .pi
        return (south, west, north, east)
    }

    /// All tiles covering a corridor of `bufferMeters` around the track,
    /// for every zoom in `zooms`. Built as the union of per-point buffered
    /// boxes, so it follows the trace instead of its whole bounding box.
    public static func corridorTiles(
        around points: [TrackPoint], bufferMeters: Double, zooms: ClosedRange<Int>
    ) -> Set<Tile> {
        var tiles = Set<Tile>()
        let metersPerDegreeLat = 111_320.0
        for zoom in zooms.lowerBound...zooms.upperBound {
            for point in points {
                let dLat = bufferMeters / metersPerDegreeLat
                let dLon = bufferMeters / (metersPerDegreeLat * cos(point.latitude * .pi / 180))
                let southWest = tile(
                    latitude: point.latitude - dLat, longitude: point.longitude - dLon, zoom: zoom)
                let northEast = tile(
                    latitude: point.latitude + dLat, longitude: point.longitude + dLon, zoom: zoom)
                for x in southWest.x...northEast.x {
                    for y in northEast.y...southWest.y {
                        tiles.insert(Tile(z: zoom, x: x, y: y))
                    }
                }
            }
        }
        return tiles
    }
}
