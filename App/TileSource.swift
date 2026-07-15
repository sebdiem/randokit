import Foundation
import RandoKit

/// A raster basemap the map can render. Everything downstream (style JSON,
/// offline downloads, cache keys) hangs off this description.
struct TileSource: Identifiable, Equatable {
    let id: String
    let name: String
    /// XYZ template with {z}/{x}/{y} placeholders (MapLibre substitutes them).
    let tileURLTemplate: String
    let attribution: String
    let maxZoom: Int
    let tileSize: Int

    static let ignPlanV2 = TileSource(
        id: "ign-plan-v2",
        name: "Plan IGN",
        tileURLTemplate:
            "https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0"
            + "&LAYER=GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2&STYLE=normal&FORMAT=image/png"
            + "&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}",
        attribution: "© IGN — Géoplateforme",
        maxZoom: 19,
        tileSize: 256)

    static let openTopoMap = TileSource(
        id: "opentopomap",
        name: "OpenTopoMap",
        tileURLTemplate: "https://tile.opentopomap.org/{z}/{x}/{y}.png",
        attribution: "© OpenStreetMap contributors, SRTM | © OpenTopoMap (CC-BY-SA)",
        maxZoom: 17,
        tileSize: 256)

    static let all: [TileSource] = [.ignPlanV2, .openTopoMap]

    static func withID(_ id: String) -> TileSource {
        all.first { $0.id == id } ?? .ignPlanV2
    }

    /// The real network URL for one tile (used by the read-through cache).
    func remoteURL(for tile: Tile) -> URL? {
        URL(
            string: tileURLTemplate
                .replacingOccurrences(of: "{z}", with: String(tile.z))
                .replacingOccurrences(of: "{x}", with: String(tile.x))
                .replacingOccurrences(of: "{y}", with: String(tile.y)))
    }

    /// Minimal MapLibre style: one raster source, one raster layer.
    private var styleDictionary: [String: Any] {
        [
            "version": 8,
            "name": name,
            "sources": [
                "base": [
                    "type": "raster",
                    // All tile traffic goes through TileURLProtocol (read-through cache).
                    "tiles": ["\(TileURLProtocol.scheme)://\(id)/{z}/{x}/{y}"],
                    "tileSize": tileSize,
                    "maxzoom": maxZoom,
                    "attribution": attribution,
                ]
            ],
            "layers": [
                ["id": "base", "type": "raster", "source": "base"]
            ],
        ]
    }

    /// Writes the style JSON under Caches and returns its file URL.
    /// Deterministic path per source, so an unchanged style never triggers a reload.
    func styleURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MapStyles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).json")
        let data = try JSONSerialization.data(withJSONObject: styleDictionary, options: [.sortedKeys])
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
        }
        return file
    }
}
