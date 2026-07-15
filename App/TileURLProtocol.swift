import Foundation
import RandoKit

/// Intercepts `rando-tile://<sourceID>/<z>/<x>/<y>` requests from MapLibre.
/// Read-through cache: serve from TileStore, else fetch the source's real
/// endpoint, persist, then serve. Every tile ever displayed stays available
/// offline. OFFLINE_ONLY=1 (env) disables network to prove offline behavior.
final class TileURLProtocol: URLProtocol {
    static let scheme = "rando-tile"
    private static let offlineOnly = ProcessInfo.processInfo.environment["OFFLINE_ONLY"] == "1"

    private var fetchTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == scheme
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let sourceID = url.host,
            url.pathComponents.count == 4,
            let z = Int(url.pathComponents[1]),
            let x = Int(url.pathComponents[2]),
            let y = Int(url.pathComponents[3])
        else {
            fail()
            return
        }
        let source = TileSource.withID(sourceID)
        let tile = Tile(z: z, x: x, y: y)

        if let cached = TileStore.shared?.data(source: source.id, tile: tile) {
            succeed(with: cached)
            return
        }
        guard !Self.offlineOnly, let remote = source.remoteURL(for: tile) else {
            fail()
            return
        }

        var remoteRequest = URLRequest(url: remote)
        remoteRequest.setValue("Rando/0.1 (personal hiking app)", forHTTPHeaderField: "User-Agent")
        fetchTask = URLSession.shared.dataTask(with: remoteRequest) { [weak self] data, response, _ in
            guard let self else { return }
            if let data, !data.isEmpty, (response as? HTTPURLResponse)?.statusCode == 200 {
                TileStore.shared?.insert(source: source.id, tile: tile, data: data)
                self.succeed(with: data)
            } else {
                self.fail()
            }
        }
        fetchTask?.resume()
    }

    override func stopLoading() {
        fetchTask?.cancel()
    }

    private func succeed(with data: Data) {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }
}
