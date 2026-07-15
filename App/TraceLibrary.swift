import Foundation
import RandoKit

extension Waypoint {
    enum Category: Equatable, Sendable {
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
    typealias Entry = TraceEntry

    struct Active: Sendable {
        let entryID: String
        let prepared: PreparedTrace
        /// Reduced profile for chart rendering only — measurements use `linearized`.
        let displayProfile: [ProfilePoint]
        /// GPX waypoints projected onto the trace (those within 250 m of it),
        /// for name lookups and on-profile placement.
        let waypointMarks: [WaypointMark]

        var trace: GPXTrace { prepared.trace }
        var linearized: LinearizedTrace { prepared.linearized }
        var projector: TraceProjector { prepared.projector }
    }

    struct WaypointMark: Equatable, Sendable {
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

    private actor PreparationService {
        func prepare(entryID: String, trace: GPXTrace) -> Active? {
            TraceLibrary.prepare(entryID: entryID, trace: trace)
        }
    }

    private let repository: TraceRepository
    private let importer: TraceImporter
    private let preparationService = PreparationService()
    private var initializationTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var deletionTask: Task<Void, Never>?

    init(
        repository: TraceRepository? = nil,
        elevationService: IGNElevationService = IGNElevationService()
    ) {
        let repository = repository ?? TraceRepository()
        self.repository = repository
        importer = TraceImporter(
            repository: repository, elevationService: elevationService)
        initializationTask = Task { [weak self] in
            await self?.initialize()
        }
    }

    private func initialize() async {
        do {
            entries = try await repository.entries()
            let lastID = UserDefaults.standard.string(forKey: "activeTraceID")
                ?? TraceRepository.sampleID
            if let entry = entries.first(where: { $0.id == lastID }) ?? entries.first {
                select(entry)
            }
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func refreshEntries() async throws {
        entries = try await repository.entries()
    }

    func select(_ entry: Entry) {
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trace = try await repository.load(entry)
                try Task.checkCancellation()
                guard let loaded = await preparationService.prepare(
                    entryID: entry.id, trace: trace)
                else { return }
                try Task.checkCancellation()
                active = loaded
                UserDefaults.standard.set(entry.id, forKey: "activeTraceID")
            } catch is CancellationError {
                return
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }

    private nonisolated static func prepare(entryID: String, trace: GPXTrace) -> Active? {
        guard trace.points.count >= 2 else { return nil }
        let prepared = PreparedTrace(trace: trace)
        let marks = trace.waypoints.compactMap { waypoint -> WaypointMark? in
            guard
                let projection = prepared.projector.project(
                    latitude: waypoint.latitude, longitude: waypoint.longitude),
                projection.crossTrackDistance < 250
            else { return nil }
            return WaypointMark(
                name: waypoint.name, km: projection.distanceAlong / 1000,
                latitude: waypoint.latitude, longitude: waypoint.longitude,
                category: waypoint.category)
        }
        return Active(
            entryID: entryID,
            prepared: prepared,
            displayProfile: prepared.linearized.downsampled(),
            waypointMarks: marks)
    }

    /// Loads a trace without selecting it (e.g. to download its tiles).
    func loadTrace(for entry: Entry) async -> GPXTrace? {
        try? await repository.load(entry)
    }

    /// Deletes a file-backed trace; falls back to the first entry if it was active.
    func delete(_ entry: Entry) {
        guard entry.url != nil, deletionTask == nil else { return }
        deletionTask = Task { [weak self] in
            guard let self else { return }
            defer { deletionTask = nil }
            do {
                try await repository.delete(entry)
                try await refreshEntries()
                if active?.entryID == entry.id, let first = entries.first {
                    select(first)
                }
            } catch is CancellationError {
                return
            } catch {
                importMessage = "Échec de la suppression : \(error.localizedDescription)"
            }
        }
    }

    /// Full import pipeline: read → parse → correct elevations against the
    /// IGN DEM (best effort) → persist as GPX in Documents → select.
    func importGPX(from url: URL) {
        guard importTask == nil else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                importTask = nil
            }
            do {
                let result = try await importer.importGPX(from: url)
                try await refreshEntries()
                if let entry = entries.first(where: { $0.id == result.entry.id }) {
                    select(entry)
                }
                importMessage = result.correctedPointCount > 0
                    ? "Importé — altitudes IGN corrigées (\(result.correctedPointCount) points)"
                    : "Importé — altitudes du fichier conservées"
            } catch is CancellationError {
                return
            } catch {
                NSLog("RANDO GPX import failed: %@", error.localizedDescription)
                importMessage = "Échec de l’import : \(error.localizedDescription)"
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }
}
