import Foundation
import RandoKit
import XCTest

@testable import Rando

final class IGNElevationServiceTests: XCTestCase {
    func testFailedMiddleBatchKeepsEntireOriginalTrace() async throws {
        let original = makeTrace(pointCount: 205)
        let service = IGNElevationService(
            dataLoader: { request in
                let longitudes = try Self.queryValues(named: "lon", in: request)
                if longitudes.first == "6.010000" {
                    return (Data(), 503)
                }
                return (try Self.response(elevations: Array(repeating: 2_000, count: longitudes.count)), 200)
            },
            retryDelaysNanoseconds: [0])

        let result = try await service.corrected(original)

        XCTAssertEqual(result.correctedPointCount, 0)
        XCTAssertEqual(result.trace, original)
    }

    func testAllBatchesCommitAfterValidation() async throws {
        let original = makeTrace(pointCount: 205)
        let service = IGNElevationService(
            dataLoader: { request in
                let count = try Self.queryValues(named: "lon", in: request).count
                return (try Self.response(elevations: Array(repeating: 2_000, count: count)), 200)
            },
            retryDelaysNanoseconds: [0])

        let result = try await service.corrected(original)

        XCTAssertEqual(result.correctedPointCount, 205)
        XCTAssertTrue(result.trace.points.allSatisfy { $0.elevation == 2_000 })
    }

    func testCancellationPropagatesWithoutAResult() async {
        let service = IGNElevationService(
            dataLoader: { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return (Data(), 200)
            },
            retryDelaysNanoseconds: [0])
        let task = Task { try await service.corrected(self.makeTrace(pointCount: 2)) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTrace(pointCount: Int) -> GPXTrace {
        GPXTrace(
            name: "Test",
            points: (0..<pointCount).map { index in
                TrackPoint(
                    latitude: 45 + Double(index) * 0.000_1,
                    longitude: 6 + Double(index) * 0.000_1,
                    elevation: Double(index))
            })
    }

    private static func queryValues(named name: String, in request: URLRequest) throws -> [String] {
        let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let value = try XCTUnwrap(components.queryItems?.first { $0.name == name }?.value)
        return value.split(separator: "|").map(String.init)
    }

    private static func response(elevations: [Double]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["elevations": elevations])
    }
}
