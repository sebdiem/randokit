import Testing

@testable import RandoKit

private func profile(_ elevations: [Double]) -> LinearizedTrace {
    // 100 m of horizontal distance between consecutive samples.
    LinearizedTrace(
        trackPoints: elevations.enumerated().map { index, elevation in
            TrackPoint(latitude: 45.0 + Double(index) * 0.0009, longitude: 6.0, elevation: elevation)
        })
}

struct ElevationStatsTests {
    @Test func steadyClimbCountsFully() {
        let stats = profile([1000, 1010, 1020, 1030, 1040]).elevationStats()
        #expect(stats.gain == 40)
        #expect(stats.loss == 0)
    }

    @Test func upDownUpSplitsGainAndLoss() {
        let stats = profile([1000, 1050, 1030, 1060]).elevationStats()
        #expect(stats.gain == 80)
        #expect(stats.loss == 20)
    }

    @Test func noiseBelowThresholdIsIgnored() {
        let stats = profile([1000, 1002, 999, 1001, 998, 1000]).elevationStats(threshold: 3)
        #expect(stats.gain == 0)
        #expect(stats.loss == 0)
    }

    @Test func rangeRestrictsToSlice() {
        // Climb over the first three points (~200 m), descent afterwards.
        let trace = profile([1000, 1050, 1100, 1080, 1060])
        let firstPart = trace.elevationStats(in: 0...210)
        #expect(firstPart.gain == 100)
        #expect(firstPart.loss == 0)
    }

    @Test func emptyTraceYieldsZero() {
        let stats = LinearizedTrace(trackPoints: []).elevationStats()
        #expect(stats == ElevationStats())
    }
}
