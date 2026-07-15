import Foundation
import RandoKit

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
        let projector: TraceProjector
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var active: Active?
    @Published private(set) var isImporting = false
    @Published var importMessage: String?

    private static let sampleID = "sample"
    private let parser = GPXParser()

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

    func select(_ entry: Entry) {
        let trace: GPXTrace?
        if let url = entry.url {
            trace = (try? Data(contentsOf: url)).flatMap { try? parser.parse($0) }
        } else {
            trace = SampleTrace.trace
        }
        guard let trace else { return }
        active = Active(
            entryID: entry.id,
            trace: trace,
            linearized: LinearizedTrace(trackPoints: trace.points),
            projector: TraceProjector(trackPoints: trace.points))
        UserDefaults.standard.set(entry.id, forKey: "activeTraceID")
    }

    /// Full import pipeline: read → parse → correct elevations against the
    /// IGN DEM (best effort) → persist as GPX in Documents → select.
    func importGPX(from url: URL) async {
        isImporting = true
        defer { isImporting = false }

        let secured = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if secured { url.stopAccessingSecurityScopedResource() }

        guard let data, var trace = try? parser.parse(data) else {
            importMessage = "Fichier GPX illisible"
            return
        }
        if trace.name == nil {
            trace.name = url.deletingPathExtension().lastPathComponent
        }

        let (corrected, count) = await IGNElevationService().corrected(trace)

        let baseName = sanitized(corrected.name ?? "Trace")
        var fileURL = documentsDirectory.appendingPathComponent("\(baseName).gpx")
        var suffix = 2
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = documentsDirectory.appendingPathComponent("\(baseName)-\(suffix).gpx")
            suffix += 1
        }
        do {
            try GPXWriter().write(corrected).write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            importMessage = "Échec de l'enregistrement"
            return
        }

        refresh()
        if let entry = entries.first(where: { $0.id == fileURL.lastPathComponent }) {
            select(entry)
        }
        importMessage = count > 0
            ? "Importé — altitudes IGN corrigées (\(count) points)"
            : "Importé — altitudes du fichier conservées"
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return String(name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }
}
