import Foundation
import RandoKit

extension Waypoint {
    enum Category: Equatable {
        case standard
        case overnightStop
        case waterSource
    }

    /// Category convention: the GPX `<sym>` or `<type>` contains a keyword
    /// (set them in gpx.studio, a text editor, …). The NAME is deliberately
    /// not matched — "Refuge du Lac Blanc" as a plain POI must not become a
    /// night stop by accident.
    var category: Category {
        let haystack = "\(symbol ?? "") \(type ?? "")".lowercased()
        guard !haystack.trimmingCharacters(in: .whitespaces).isEmpty else { return .standard }
        let overnight = [
            "campground", "camping", "camp", "tent", "bivouac", "bivy",
            "lodging", "hotel", "hut", "refuge", "gite", "gîte",
            "nuit", "night", "etape", "étape",
        ]
        if overnight.contains(where: { haystack.contains($0) }) {
            return .overnightStop
        }
        let water = ["water", "eau", "fontaine", "fountain", "source", "spring"]
        if water.contains(where: { haystack.contains($0) }) {
            return .waterSource
        }
        return .standard
    }
}

/// The app's traces: plain GPX files in Documents (visible in the Files app),
/// plus the bundled sample. Selecting an entry loads and pre-computes
/// everything the UI needs (linearization, projector).
@MainActor
final class TraceLibrary: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let url: URL?
    }

    struct Active {
        let entryID: String
        let trace: GPXTrace
        let linearized: LinearizedTrace
        /// Reduced profile for chart rendering only — measurements use `linearized`.
        let displayProfile: [ProfilePoint]
        let projector: TraceProjector
        /// GPX waypoints projected onto the trace (those within 250 m of it),
        /// for name lookups and on-profile placement.
        let waypointMarks: [WaypointMark]
    }

    struct WaypointMark: Equatable {
        let name: String?
        let km: Double
        let latitude: Double
        let longitude: Double
        let category: Waypoint.Category
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var active: Active?
    @Published private(set) var isImporting = false
    @Published var importMessage: String?

    private static let sampleID = "sample"

    init() {
        refresh()
        let lastID = UserDefaults.standard.string(forKey: "activeTraceID") ?? Self.sampleID
        select(entries.first { $0.id == lastID } ?? entries[0])
    }

    func refresh() {
        var result = [Entry(id: Self.sampleID, name: "Exemple : La Flégère → Lac Blanc", url: nil)]
        if let files = try? FileManager.default.contentsOfDirectory(
            at: documentsDirectory, includingPropertiesForKeys: nil)
        {
            let gpxFiles = files
                .filter { $0.pathExtension.lowercased() == "gpx" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            result += gpxFiles.map {
                Entry(
                    id: $0.lastPathComponent,
                    name: $0.deletingPathExtension().lastPathComponent,
                    url: $0)
            }
        }
        entries = result
    }

    private var selectionGeneration = 0

    func select(_ entry: Entry) {
        selectionGeneration += 1
        let generation = selectionGeneration
        Task { await selectAsync(entry, generation: generation) }
    }

    private func selectAsync(_ entry: Entry, generation: Int) async {
        // File IO, XML parsing, and the O(n) derived models stay off-main.
        guard
            let loaded = await Task.detached(
                priority: .userInitiated, operation: { Self.load(entry) }
            ).value
        else { return }
        // Selections can race (slow big-trace load vs a quick import's
        // select): only the LATEST requested selection may apply.
        guard generation == selectionGeneration else { return }
        active = loaded
        UserDefaults.standard.set(entry.id, forKey: "activeTraceID")
    }

    private nonisolated static func load(_ entry: Entry) -> Active? {
        let trace: GPXTrace?
        if let url = entry.url {
            trace = (try? Data(contentsOf: url)).flatMap { try? GPXParser().parse($0) }
        } else {
            trace = SampleTrace.trace
        }
        guard let trace, trace.points.count >= 2 else { return nil }
        let linearized = LinearizedTrace(trackPoints: trace.points)
        let projector = TraceProjector(trace: trace)
        let marks = trace.waypoints.compactMap { waypoint -> WaypointMark? in
            guard
                let projection = projector.project(
                    latitude: waypoint.latitude, longitude: waypoint.longitude),
                projection.crossTrackDistance < 250
            else { return nil }
            return WaypointMark(
                name: waypoint.name, km: projection.distanceAlong / 1000,
                latitude: waypoint.latitude, longitude: waypoint.longitude,
                category: waypoint.category)
        }
        return Active(
            entryID: entry.id,
            trace: trace,
            linearized: linearized,
            displayProfile: linearized.downsampled(),
            projector: projector,
            waypointMarks: marks)
    }

    /// Loads a trace without selecting it (e.g. to download its tiles).
    func loadTrace(for entry: Entry) async -> GPXTrace? {
        await Task.detached(priority: .userInitiated) { Self.load(entry)?.trace }.value
    }

    /// Deletes a file-backed trace; falls back to the first entry if it was active.
    func delete(_ entry: Entry) {
        guard let url = entry.url else { return }
        try? FileManager.default.removeItem(at: url)
        refresh()
        if active?.entryID == entry.id, let first = entries.first {
            select(first)
        }
    }

    /// Full import pipeline: read → parse → correct elevations against the
    /// IGN DEM (best effort) → persist as GPX in Documents → select.
    func importGPX(from url: URL) async {
        isImporting = true
        defer { isImporting = false }

        let parsed = await Task.detached(priority: .userInitiated) { () -> GPXTrace? in
            let secured = url.startAccessingSecurityScopedResource()
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? GPXParser().parse(data)
        }.value
        guard var trace = parsed else {
            importMessage = "Fichier GPX illisible"
            return
        }
        if trace.name == nil {
            trace.name = url.deletingPathExtension().lastPathComponent
        }

        let (corrected, count) = await IGNElevationService().corrected(trace)

        let baseName = sanitized(corrected.name ?? "Trace")
        let existingNames = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: documentsDirectory.path))?
                .map(normalizedFileName) ?? [])
        var fileURL = documentsDirectory.appendingPathComponent("\(baseName).gpx")
        var suffix = 2
        while existingNames.contains(normalizedFileName(fileURL.lastPathComponent)) {
            fileURL = documentsDirectory.appendingPathComponent("\(baseName)-\(suffix).gpx")
            suffix += 1
        }
        let content = GPXWriter().write(corrected)
        let destination = fileURL
        let saveError = await Task.detached { () -> String? in
            do {
                // The destination is computed as unique above. Refuse to overwrite
                // if another import creates the same file before this write starts.
                try Data(content.utf8).write(to: destination, options: .withoutOverwriting)
                return nil
            } catch {
                let nsError = error as NSError
                return "\(error.localizedDescription) (\(nsError.domain) \(nsError.code))"
            }
        }.value
        guard let saveError else {
            refresh()
            if let entry = entries.first(where: { $0.id == fileURL.lastPathComponent }) {
                select(entry)
            }
            importMessage = count > 0
                ? "Importé — altitudes IGN corrigées (\(count) points)"
                : "Importé — altitudes du fichier conservées"
            return
        }
        NSLog("RANDO GPX save failed: %@", saveError)
        importMessage = "Échec de l'enregistrement : \(saveError)"
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return String(name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }

    private func normalizedFileName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
