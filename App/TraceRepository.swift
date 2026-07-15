import Foundation
import RandoKit

struct TraceEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL?
}

enum TraceRepositoryError: LocalizedError {
    case sampleUnavailable
    case invalidTrace

    var errorDescription: String? {
        switch self {
        case .sampleUnavailable: "La trace d’exemple est indisponible"
        case .invalidTrace: "Fichier GPX illisible"
        }
    }
}

/// Serial persistence boundary for GPX files. Keeping filename allocation and
/// the write in one actor removes import races without locking the UI thread.
actor TraceRepository {
    static let sampleID = "sample"

    private let documentsDirectory: URL
    private let sampleTrace: GPXTrace?
    private let fileManager: FileManager

    init(
        documentsDirectory: URL? = nil,
        sampleTrace: GPXTrace? = SampleTrace.trace,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.documentsDirectory = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.sampleTrace = sampleTrace
    }

    func entries() throws -> [TraceEntry] {
        try fileManager.createDirectory(
            at: documentsDirectory, withIntermediateDirectories: true)
        let files = try fileManager.contentsOfDirectory(
            at: documentsDirectory, includingPropertiesForKeys: nil)
        let gpxFiles = files
            .filter { $0.pathExtension.lowercased() == "gpx" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let sampleEntries = sampleTrace == nil
            ? []
            : [
                TraceEntry(
                    id: Self.sampleID, name: "Exemple : La Flégère → Lac Blanc", url: nil)
            ]
        return sampleEntries + gpxFiles.map {
            TraceEntry(
                id: $0.lastPathComponent,
                name: $0.deletingPathExtension().lastPathComponent,
                url: $0)
        }
    }

    func load(_ entry: TraceEntry) throws -> GPXTrace {
        if let url = entry.url {
            let trace = try GPXParser().parse(Data(contentsOf: url))
            guard trace.points.count >= 2 else { throw TraceRepositoryError.invalidTrace }
            return trace
        }
        guard let sampleTrace else { throw TraceRepositoryError.sampleUnavailable }
        return sampleTrace
    }

    func save(_ trace: GPXTrace) throws -> TraceEntry {
        try fileManager.createDirectory(
            at: documentsDirectory, withIntermediateDirectories: true)
        let baseName = sanitized(trace.name ?? "Trace")
        let existingNames = Set(
            try fileManager.contentsOfDirectory(atPath: documentsDirectory.path)
                .map(normalizedFileName))
        var fileURL = documentsDirectory.appendingPathComponent("\(baseName).gpx")
        var suffix = 2
        while existingNames.contains(normalizedFileName(fileURL.lastPathComponent)) {
            fileURL = documentsDirectory.appendingPathComponent("\(baseName)-\(suffix).gpx")
            suffix += 1
        }

        let content = GPXWriter().write(trace)
        try Data(content.utf8).write(to: fileURL, options: .withoutOverwriting)
        return TraceEntry(
            id: fileURL.lastPathComponent,
            name: fileURL.deletingPathExtension().lastPathComponent,
            url: fileURL)
    }

    func delete(_ entry: TraceEntry) throws {
        guard let url = entry.url else { return }
        try fileManager.removeItem(at: url)
    }

    private func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = String(
            name.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Trace" : sanitized
    }

    private func normalizedFileName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
