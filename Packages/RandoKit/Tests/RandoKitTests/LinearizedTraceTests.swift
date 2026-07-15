import Foundation
import Testing

@testable import RandoKit

struct LinearizedTraceTests {
    @Test func distanceAccumulatesAlongLatitude() {
        // 0.01° of latitude ≈ 1111.95 m regardless of longitude.
        let points = [
            TrackPoint(latitude: 45.00, longitude: 6.0, elevation: 1000),
            TrackPoint(latitude: 45.01, longitude: 6.0, elevation: 1100),
            TrackPoint(latitude: 45.02, longitude: 6.0, elevation: 1050),
        ]
        let trace = LinearizedTrace(trackPoints: points)
        #expect(trace.points.count == 3)
        #expect(trace.points[0].distance == 0)
        #expect(abs(trace.points[1].distance - 1111.95) < 1.0)
        #expect(abs(trace.totalDistance - 2223.9) < 2.0)
    }

    @Test func missingElevationCarriesLastKnownValue() {
        let points = [
            TrackPoint(latitude: 45.00, longitude: 6.0, elevation: nil),
            TrackPoint(latitude: 45.01, longitude: 6.0, elevation: 1200),
            TrackPoint(latitude: 45.02, longitude: 6.0, elevation: nil),
        ]
        let trace = LinearizedTrace(trackPoints: points)
        #expect(trace.points[0].elevation == 1200)  // first known value backfills the start
        #expect(trace.points[2].elevation == 1200)
    }

    @Test func emptyTraceIsEmpty() {
        let trace = LinearizedTrace(trackPoints: [])
        #expect(trace.points.isEmpty)
        #expect(trace.totalDistance == 0)
    }

    @Test func downsamplingPreservesExtremesAndEndpoints() {
        // 8000 points with a single sharp spike and dip hidden in the noise.
        var points: [TrackPoint] = []
        for i in 0..<8000 {
            var elevation = 1000.0 + Double(i % 7)
            if i == 3210 { elevation = 2500 }
            if i == 6100 { elevation = 400 }
            points.append(
                TrackPoint(latitude: 45 + Double(i) * 0.0001, longitude: 6, elevation: elevation))
        }
        let full = LinearizedTrace(trackPoints: points)
        let reduced = full.downsampled(maxBuckets: 500)

        #expect(reduced.count <= 1002)
        #expect(reduced.count > 400)
        #expect(reduced.map(\.elevation).max() == 2500)
        #expect(reduced.map(\.elevation).min() == 400)
        #expect(reduced.first == full.points.first)
        #expect(reduced.last == full.points.last)
        // Still sorted by distance so the chart renders a valid path.
        #expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.distance <= $1.distance })
    }

    @Test func downsamplingLeavesSmallTracesUntouched() {
        let trace = LinearizedTrace(trackPoints: (0..<100).map {
            TrackPoint(latitude: 45 + Double($0) * 0.001, longitude: 6, elevation: 1000)
        })
        #expect(trace.downsampled(maxBuckets: 500) == trace.points)
    }

    @Test func rangedDownsamplingInterpolatesBoundaries() {
        // Points every ~111 m, elevation climbing 10 m per point.
        let trace = LinearizedTrace(trackPoints: (0..<50).map {
            TrackPoint(latitude: 45 + Double($0) * 0.001, longitude: 6, elevation: 1000 + Double($0) * 10)
        })
        let slice = trace.downsampled(in: 150...450, maxBuckets: 500)

        let first = slice.first!
        let last = slice.last!
        #expect(first.distance == 150)
        #expect(last.distance == 450)
        // Interpolated: 150 m is between samples at ~111 and ~222 m.
        #expect(abs(first.elevation - (1000 + 150 / 111.195 * 10)) < 0.5)
        #expect(abs(last.elevation - (1000 + 450 / 111.195 * 10)) < 0.5)
        // Small slice passes through at full resolution, sorted.
        #expect(slice.count >= 3)
        #expect(zip(slice, slice.dropFirst()).allSatisfy { $0.distance <= $1.distance })
    }

    @Test func rangedDownsamplingReducesLargeSlices() {
        let trace = LinearizedTrace(trackPoints: (0..<8000).map {
            TrackPoint(latitude: 45 + Double($0) * 0.0001, longitude: 6, elevation: 1000 + Double($0 % 13))
        })
        let full = trace.downsampled(in: 0...trace.totalDistance, maxBuckets: 100)
        #expect(full.count <= 202)
    }

    @Test func disconnectedSegmentGapAddsNoDistanceOrElevationGain() {
        let trace = GPXTrace(
            points: [
                TrackPoint(latitude: 45.000, longitude: 6.00, elevation: 100),
                TrackPoint(latitude: 45.001, longitude: 6.00, elevation: 110),
                TrackPoint(latitude: 46.000, longitude: 7.00, elevation: 1_000),
                TrackPoint(latitude: 46.001, longitude: 7.00, elevation: 1_010),
            ],
            segmentRanges: [0..<2, 2..<4])
        let linearized = LinearizedTrace(trace: trace)

        // Only the two ~111 m real segments count, not the ~135 km gap.
        #expect(abs(linearized.totalDistance - 222.4) < 2)
        #expect(linearized.points[1].distance == linearized.points[2].distance)
        #expect(linearized.points.map(\.segmentIndex) == [0, 0, 1, 1])
        let stats = linearized.elevationStats(threshold: 0)
        #expect(stats.gain == 20)
        #expect(stats.loss == 0)
    }

    @Test func rangedDownsamplingKeepsDisconnectedSeriesSeparate() {
        let first = (0..<1_000).map {
            TrackPoint(
                latitude: 45 + Double($0) * 0.00001, longitude: 6,
                elevation: 1_000 + Double($0 % 11))
        }
        let second = (0..<1_000).map {
            TrackPoint(
                latitude: 46 + Double($0) * 0.00001, longitude: 7,
                elevation: 2_000 + Double($0 % 13))
        }
        let trace = LinearizedTrace(
            trace: GPXTrace(
                points: first + second,
                segmentRanges: [0..<first.count, first.count..<(first.count + second.count)]))
        let reduced = trace.downsampled(maxBuckets: 100)

        #expect(Set(reduced.map(\.segmentIndex)) == [0, 1])
        #expect(reduced.count <= 204)
    }
}
