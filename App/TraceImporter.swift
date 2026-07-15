import Foundation
import RandoKit

struct TraceImportResult: Sendable {
    let entry: TraceEntry
    let correctedPointCount: Int
}

/// Import use case: security-scoped read → parse → transactional elevation
/// correction → serialized repository write.
actor TraceImporter {
    private let repository: TraceRepository
    private let elevationService: IGNElevationService

    init(repository: TraceRepository, elevationService: IGNElevationService) {
        self.repository = repository
        self.elevationService = elevationService
    }

    func importGPX(from url: URL) async throws -> TraceImportResult {
        try Task.checkCancellation()
        let secured = url.startAccessingSecurityScopedResource()
        let data: Data
        do {
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
            }
            data = try Data(contentsOf: url)
        }

        var trace: GPXTrace
        do {
            trace = try GPXParser().parse(data)
        } catch {
            throw TraceRepositoryError.invalidTrace
        }
        if trace.name == nil {
            trace.name = url.deletingPathExtension().lastPathComponent
        }

        let correction = try await elevationService.corrected(trace)
        try Task.checkCancellation()
        let entry = try await repository.save(correction.trace)
        return TraceImportResult(
            entry: entry, correctedPointCount: correction.correctedPointCount)
    }
}
