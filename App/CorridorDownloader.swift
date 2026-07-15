import Foundation
import RandoKit

/// Pre-warms the TileStore with every tile in a corridor around a trace.
@MainActor
final class CorridorDownloader: ObservableObject {
    /// nil = idle, otherwise 0...1.
    @Published private(set) var progress: Double?
    @Published private(set) var lastResult: String?

    static let bufferMeters = 1000.0
    static let zooms = 10...16

    private var downloadTask: Task<Void, Never>?

    func startDownload(trace: GPXTrace, source: TileSource) {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloadTask = nil }
            await download(trace: trace, source: source)
        }
    }

    func startDownload(
        source: TileSource,
        loadTrace: @escaping @MainActor @Sendable () async -> GPXTrace?
    ) {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { downloadTask = nil }
            guard let trace = await loadTrace(), !Task.isCancelled else { return }
            await download(trace: trace, source: source)
        }
    }

    func cancel() {
        downloadTask?.cancel()
    }

    private func download(trace: GPXTrace, source: TileSource) async {
        guard progress == nil, let store = TileStore.shared else { return }
        progress = 0
        defer { progress = nil }

        let zooms = Self.zooms.lowerBound...min(Self.zooms.upperBound, source.maxZoom)
        let bufferMeters = Self.bufferMeters
        // Corridor planning + cache lookups off the main thread.
        let (missing, wantedCount) = await Task.detached(priority: .userInitiated) {
            () -> ([Tile], Int) in
            let wanted = TileMath.corridorTiles(
                around: trace, bufferMeters: bufferMeters, zooms: zooms)
            let missing = wanted
                .filter { !store.contains(source: source.id, tile: $0) }
                .sorted { ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y) }
            return (missing, wanted.count)
        }.value

        guard !Task.isCancelled else { return }

        guard !missing.isEmpty else {
            lastResult = "Déjà hors-ligne (\(wantedCount) tuiles)"
            return
        }

        var completed = 0
        var failed = 0
        // Two concurrent fetches: fast enough for corridor volumes, polite to
        // donation-run tile servers.
        await withTaskGroup(of: Bool.self) { group in
            var iterator = missing.makeIterator()
            func enqueueNext() {
                guard !Task.isCancelled, let tile = iterator.next() else { return }
                group.addTask {
                    await Self.fetchAndStore(tile: tile, source: source, into: store)
                }
            }
            enqueueNext()
            enqueueNext()
            for await success in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                completed += 1
                if !success { failed += 1 }
                progress = Double(completed) / Double(missing.count)
                enqueueNext()
            }
        }

        guard !Task.isCancelled else { return }
        lastResult = failed == 0
            ? "\(missing.count) tuiles téléchargées"
            : "\(missing.count - failed)/\(missing.count) tuiles (échecs: \(failed))"
    }

    /// True only if the tile was fetched AND committed to the store.
    private nonisolated static func fetchAndStore(
        tile: Tile, source: TileSource, into store: TileStore
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let url = source.remoteURL(for: tile) else { return false }
        var request = URLRequest(url: url)
        request.setValue("Rando/0.1 (personal hiking app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
        else { return false }
        return store.insert(source: source.id, tile: tile, data: data)
    }
}
