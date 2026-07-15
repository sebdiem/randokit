import Foundation
import Testing

@testable import RandoKit

struct TileMathTests {
    @Test func tileBoundsRoundTripContainsCoordinate() {
        let lat = 45.9614, lon = 6.8871
        for zoom in [8, 12, 16] {
            let tile = TileMath.tile(latitude: lat, longitude: lon, zoom: zoom)
            let bounds = TileMath.bounds(of: tile)
            #expect(bounds.south <= lat && lat <= bounds.north)
            #expect(bounds.west <= lon && lon <= bounds.east)
        }
    }

    @Test func zoomZeroIsSingleWorldTile() {
        #expect(TileMath.tile(latitude: 45, longitude: 6, zoom: 0) == Tile(z: 0, x: 0, y: 0))
        #expect(TileMath.tile(latitude: -80, longitude: 179.9, zoom: 0) == Tile(z: 0, x: 0, y: 0))
    }

    @Test func corridorContainsEveryPointTile() {
        let points = [
            TrackPoint(latitude: 45.9614, longitude: 6.8871),
            TrackPoint(latitude: 45.9700, longitude: 6.8900),
            TrackPoint(latitude: 45.9801, longitude: 6.8859),
        ]
        let tiles = TileMath.corridorTiles(
            around: GPXTrace(points: points), bufferMeters: 500, zooms: 10...14)
        for zoom in 10...14 {
            for point in points {
                let tile = TileMath.tile(latitude: point.latitude, longitude: point.longitude, zoom: zoom)
                #expect(tiles.contains(tile))
            }
        }
    }

    @Test func corridorIsSmallerThanBoundingBoxForLShapedTrace() {
        // An L-shaped trace: corridor should skip the far corner of the bbox.
        var points: [TrackPoint] = []
        for i in 0...20 { points.append(TrackPoint(latitude: 45.90 + Double(i) * 0.005, longitude: 6.80)) }
        for i in 0...20 { points.append(TrackPoint(latitude: 46.00, longitude: 6.80 + Double(i) * 0.007)) }
        let corridor = TileMath.corridorTiles(
            around: GPXTrace(points: points), bufferMeters: 300, zooms: 14...14)

        let southWest = TileMath.tile(latitude: 45.90, longitude: 6.80, zoom: 14)
        let northEast = TileMath.tile(latitude: 46.00, longitude: 6.94, zoom: 14)
        let bboxCount = (northEast.x - southWest.x + 1) * (southWest.y - northEast.y + 1)
        #expect(corridor.count < bboxCount)

        // The bbox corner far from both legs must not be in the corridor.
        let farCorner = TileMath.tile(latitude: 45.905, longitude: 6.93, zoom: 14)
        #expect(!corridor.contains(farCorner))
    }

    @Test func sparselySampledSegmentIsCoveredBetweenPoints() {
        // Two points ~4.4 km apart with a 500 m buffer: the midpoint used to
        // fall outside every per-point box.
        let points = [
            TrackPoint(latitude: 45.90, longitude: 6.80),
            TrackPoint(latitude: 45.94, longitude: 6.80),
        ]
        let corridor = TileMath.corridorTiles(
            around: GPXTrace(points: points), bufferMeters: 500, zooms: 15...15)
        let midpoint = TileMath.tile(latitude: 45.92, longitude: 6.80, zoom: 15)
        #expect(corridor.contains(midpoint))
    }

    @Test func corridorSkipsGapBetweenSegments() {
        // Two disconnected segments far apart: nothing should be downloaded
        // along the artificial straight line joining them.
        let points = [
            TrackPoint(latitude: 45.90, longitude: 6.80),
            TrackPoint(latitude: 45.905, longitude: 6.80),
            TrackPoint(latitude: 45.99, longitude: 6.80),
            TrackPoint(latitude: 45.995, longitude: 6.80),
        ]
        let trace = GPXTrace(points: points, segmentRanges: [0..<2, 2..<4])
        let corridor = TileMath.corridorTiles(around: trace, bufferMeters: 300, zooms: 15...15)
        let gapMidpoint = TileMath.tile(latitude: 45.9475, longitude: 6.80, zoom: 15)
        #expect(!corridor.contains(gapMidpoint))
    }
}
