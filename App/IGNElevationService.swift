import Foundation
import RandoKit

/// Replaces trace elevations with values from IGN's RGE ALTI DEM
/// (Géoplateforme altimetry API). France-only: outside coverage the API
/// returns a sentinel and the original GPX elevation is kept. Correction is
/// best-effort — any network failure keeps the trace as imported.
struct IGNElevationService {
    private static let endpoint = "https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json"
    private static let batchSize = 100
    /// The API answers -99999 for points outside DEM coverage.
    private static let noDataFloor = -1000.0

    private struct Response: Decodable {
        let elevations: [Double]
    }

    func corrected(_ trace: GPXTrace) async -> (trace: GPXTrace, correctedPointCount: Int) {
        var corrected = trace.points
        var count = 0
        for batchStart in stride(from: 0, to: trace.points.count, by: Self.batchSize) {
            let batch = Array(trace.points[batchStart..<min(batchStart + Self.batchSize, trace.points.count)])
            guard let elevations = await fetchElevations(for: batch) else { continue }
            for (offset, elevation) in elevations.enumerated() where elevation > Self.noDataFloor {
                corrected[batchStart + offset].elevation = elevation
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
    private func fetchElevations(for points: [TrackPoint]) async -> [Double]? {
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "lon", value: points.map { String(format: "%.6f", $0.longitude) }.joined(separator: "|")),
            URLQueryItem(name: "lat", value: points.map { String(format: "%.6f", $0.latitude) }.joined(separator: "|")),
            URLQueryItem(name: "resource", value: "ign_rge_alti_wld"),
            URLQueryItem(name: "zonly", value: "true"),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Rando/0.1 (personal hiking app)", forHTTPHeaderField: "User-Agent")

        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let decoded = try? JSONDecoder().decode(Response.self, from: data),
                decoded.elevations.count == points.count
            else { continue }
            return decoded.elevations
        }
        return nil
    }
}
