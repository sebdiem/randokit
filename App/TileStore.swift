import Foundation
import RandoKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Permanent tile cache in an MBTiles-like SQLite layout, keyed per source.
/// Inspectable with any sqlite3 client. No eviction: hiking regions are
/// hundreds of MB at most and disappearing offline maps are worse than disk use.
final class TileStore: @unchecked Sendable {
    static let shared: TileStore? = try? TileStore()

    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "dev.seb.rando.tilestore")

    private init() throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let path = directory.appendingPathComponent("tiles.sqlite").path

        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(
                path, &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            let handle
        else {
            sqlite3_close(handle)
            throw NSError(domain: "TileStore", code: 1)
        }
        db = handle
        sqlite3_exec(
            db,
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS tiles(
              source TEXT NOT NULL,
              z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
              data BLOB NOT NULL,
              fetched_at INTEGER NOT NULL,
              PRIMARY KEY(source, z, x, y)
            ) WITHOUT ROWID;
            """,
            nil, nil, nil)
    }

    func data(source: String, tile: Tile) -> Data? {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard
                sqlite3_prepare_v2(
                    db, "SELECT data FROM tiles WHERE source=? AND z=? AND x=? AND y=?",
                    -1, &statement, nil) == SQLITE_OK
            else { return nil }
            sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(tile.z))
            sqlite3_bind_int(statement, 3, Int32(tile.x))
            sqlite3_bind_int(statement, 4, Int32(tile.y))
            guard sqlite3_step(statement) == SQLITE_ROW,
                let blob = sqlite3_column_blob(statement, 0)
            else { return nil }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
        }
    }

    func contains(source: String, tile: Tile) -> Bool {
        data(source: source, tile: tile) != nil
    }

    func insert(source: String, tile: Tile, data: Data) {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard
                sqlite3_prepare_v2(
                    db,
                    "INSERT OR REPLACE INTO tiles(source,z,x,y,data,fetched_at) VALUES(?,?,?,?,?,?)",
                    -1, &statement, nil) == SQLITE_OK
            else { return }
            sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(tile.z))
            sqlite3_bind_int(statement, 3, Int32(tile.x))
            sqlite3_bind_int(statement, 4, Int32(tile.y))
            data.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(
                    statement, 5, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(statement, 6, Int64(Date().timeIntervalSince1970))
            _ = sqlite3_step(statement)
        }
    }

    func tileCount(source: String? = nil) -> Int {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = source == nil
                ? "SELECT COUNT(*) FROM tiles"
                : "SELECT COUNT(*) FROM tiles WHERE source=?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
            if let source {
                sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
}
