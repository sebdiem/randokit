import Foundation
import RandoKit
import XCTest

@testable import Rando

final class TraceRepositoryTests: XCTestCase {
    func testSerialSaveAllocatesUniqueNamesAndRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = TraceRepository(
            documentsDirectory: directory, sampleTrace: nil)
        let trace = GPXTrace(
            name: "Same/Name",
            points: [
                TrackPoint(latitude: 45, longitude: 6, elevation: 1_000),
                TrackPoint(latitude: 45.001, longitude: 6, elevation: 1_010),
            ])

        async let first = repository.save(trace)
        async let second = repository.save(trace)
        let entries = try await [first, second]

        XCTAssertEqual(Set(entries.map(\.id)), ["Same-Name.gpx", "Same-Name-2.gpx"])
        let loaded = try await repository.load(entries[0])
        XCTAssertEqual(loaded, trace)
    }
}
