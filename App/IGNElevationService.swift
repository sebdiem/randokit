import Foundation
import RandoKit

/// Replaces trace elevations with values from IGN's RGE ALTI DEM
/// (Géoplateforme altimetry API). France-only: outside coverage the API
/// returns a sentinel and the original GPX elevation is kept. Correction is
/// best-effort — any network failure keeps the ENTIRE trace as imported.
/// Successful batches are staged and committed atomically so mixed elevation
/// sources cannot create artificial climb at a failed batch boundary.
struct IGNElevationService: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (data: Data, statusCode: Int)

    private static let endpoint = "https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json"
    private static let batchSize = 100
    /// The API answers -99999 for points outside DEM coverage.
    private static let noDataFloor = -1000.0

    private struct Response: Decodable {
        let elevations: [Double]
    }

    private enum ServiceError: Error {
        case invalidResponse
    }

    private let dataLoader: DataLoader
    private let retryDelaysNanoseconds: [UInt64]

    init(
        dataLoader: @escaping DataLoader = { request in
            try await IGNElevationService.liveDataLoader(request)
        },
        retryDelaysNanoseconds: [UInt64] = [0, 700_000_000, 1_400_000_000]
    ) {
        self.dataLoader = dataLoader
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
    }

    func corrected(
        _ trace: GPXTrace
    ) async throws -> (trace: GPXTrace, correctedPointCount: Int) {
        var stagedBatches: [(start: Int, elevations: [Double])] = []
        stagedBatches.reserveCapacity((trace.points.count + Self.batchSize - 1) / Self.batchSize)

        do {
            for batchStart in stride(from: 0, to: trace.points.count, by: Self.batchSize) {
                try Task.checkCancellation()
                let batch = Array(
                    trace.points[
                        batchStart..<min(batchStart + Self.batchSize, trace.points.count)])
                let elevations = try await fetchElevations(for: batch)
                stagedBatches.append((batchStart, elevations))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Best effort is transactional: one failed batch keeps the original
            // trace, rather than introducing a seam between elevation sources.
            return (trace, 0)
        }

        var corrected = trace.points
        var count = 0
        for staged in stagedBatches {
            for (offset, elevation) in staged.elevations.enumerated()
                where elevation > Self.noDataFloor
            {
                corrected[staged.start + offset].elevation = elevation
                count += 1
            }
        }
        var result = trace
        result.points = corrected
        return (result, count)
    }

    /// One batch, with retries: transient failures otherwise leave silent
    /// gaps of uncorrected points mid-trace (mixed elevation sources create
    /// seams that fabricate climb).
    private func fetchElevations(for points: [TrackPoint]) async throws -> [Double] {
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "lon", value: points.map { String(format: "%.6f", $0.longitude) }.joined(separator: "|")),
            URLQueryItem(name: "lat", value: points.map { String(format: "%.6f", $0.latitude) }.joined(separator: "|")),
            URLQueryItem(name: "resource", value: "ign_rge_alti_wld"),
            URLQueryItem(name: "zonly", value: "true"),
        ]
        guard let url = components?.url else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Rando/0.1 (personal hiking app)", forHTTPHeaderField: "User-Agent")

        var lastError: Error = ServiceError.invalidResponse
        for delay in retryDelaysNanoseconds {
            try Task.checkCancellation()
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                let response = try await dataLoader(request)
                guard response.statusCode == 200,
                    let decoded = try? JSONDecoder().decode(Response.self, from: response.data),
                    decoded.elevations.count == points.count
                else { throw ServiceError.invalidResponse }
                return decoded.elevations
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func liveDataLoader(
        _ request: URLRequest
    ) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        return (data, response.statusCode)
    }
}
