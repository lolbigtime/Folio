//
//  Database.swift
//  DataKit
//
//  Created by Tai Wong on 9/2/25.
//

import Foundation
import GRDB

internal struct AppDatabase {
    
    internal let dbQueue: DatabaseQueue
    
    internal init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }
    
    public init(url: URL) throws { try self.init(path: url.path) }

    private func migrate() throws {
        
        let urls = (Bundle.module.urls(forResourcesWithExtension: "sql", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        
        guard !urls.isEmpty else {
            throw NSError(domain: "Folio", code: 1001,
              userInfo: [NSLocalizedDescriptionKey: "No SQL migrations in Resources/."])
        }
        
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
            for u in urls {
                let sql = try String(contentsOf: u, encoding: .utf8)
                try db.execute(sql: sql)
            }

            try ensureVectorSchema(db: db)
        }
    }
}

private extension AppDatabase {
    func ensureVectorSchema(db: Database) throws {
        let tableExists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='doc_chunk_vectors')"
        ) ?? false

        guard tableExists else {
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS doc_chunk_vectors (
                  chunk_id TEXT PRIMARY KEY,
                  dim      INTEGER NOT NULL,
                  vec      BLOB    NOT NULL,
                  FOREIGN KEY(chunk_id) REFERENCES doc_chunks(id) ON DELETE CASCADE
                );
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_vectors_chunk_id ON doc_chunk_vectors(chunk_id);")
            return
        }

        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(doc_chunk_vectors)")
        let hasChunkId = columns.contains { (row: Row) -> Bool in
            let name: String = row["name"]
            return name == "chunk_id"
        }

        if hasChunkId {
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_vectors_chunk_id ON doc_chunk_vectors(chunk_id);")
            return
        }

        struct LegacyVectorRow {
            let chunkRowid: Int64
            let dim: Int
            let vec: Data
        }

        let legacyRows = try Row.fetchAll(
            db,
            sql: "SELECT rowid AS chunk_rowid, dim, vec FROM doc_chunk_vectors"
        ).map { row in
            LegacyVectorRow(
                chunkRowid: row["chunk_rowid"],
                dim: row["dim"],
                vec: row["vec"]
            )
        }

        try db.execute(sql: "DROP TABLE doc_chunk_vectors")
        try db.execute(sql: """
            CREATE TABLE doc_chunk_vectors (
              chunk_id TEXT PRIMARY KEY,
              dim      INTEGER NOT NULL,
              vec      BLOB    NOT NULL,
              FOREIGN KEY(chunk_id) REFERENCES doc_chunks(id) ON DELETE CASCADE
            );
        """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_vectors_chunk_id ON doc_chunk_vectors(chunk_id);")

        for legacy in legacyRows {
            guard let chunkId = try String.fetchOne(
                db,
                sql: "SELECT id FROM doc_chunks WHERE rowid = ?",
                arguments: [legacy.chunkRowid]
            ) else { continue }

            try db.execute(
                sql: "INSERT OR REPLACE INTO doc_chunk_vectors(chunk_id, dim, vec) VALUES (?, ?, ?)",
                arguments: [chunkId, legacy.dim, legacy.vec]
            )
        }
    }
}

