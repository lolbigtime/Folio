//
//  DocChunkStore.swift
//  DataKit
//
//  Created by Tai Wong on 9/2/25.
//

import Foundation
import GRDB
import CryptoKit

public struct Snippet: Codable, Hashable, Sendable {
    public let sourceId: String
    public let page: Int?
    public let excerpt: String
    public let score: Double
}

public struct Source: Equatable, Hashable, Codable {
    public let id: String
    public let filePath: String
    public let displayName: String
    public let pages: Int?
    public let chunks: Int
    public let importedAt: String
}

extension DocChunkStore {
    
    public struct SnippetHit: Sendable, Hashable {
        public let rowid: Int64
        public let sourceId: String
        public let page: Int?
        public let excerpt: String
        public let bm25: Double
    }

    public struct NeighborChunk: Sendable {
        public let rowid: Int64
        public let text: String
        public let page: Int?
    }
    
    func cacheKey(sourceId: String, page: Int?, chunk:String) -> String {
        let base = "\(sourceId)|\(page ?? -1)|\(chunk)"
        let d = SHA256.hash(data: Data(base.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }
    
    func getCachedPrefix(for key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM prefix_cache WHERE key = ?", arguments: [key])
        }
    }
    
    func putCachedPrefix(key: String, value: String, metaJSON: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO prefix_cache(key, value, meta)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, meta=excluded.meta
                """,
                arguments: [key, value, metaJSON]
            )
        }
    }
    
    func ftsHits(query: String, inSource source: String? = nil, limit: Int = 10) throws -> [SnippetHit] {
        try dbQueue.read { db in
            var sql = """
            SELECT
              d.rowid AS rowid,
              d.source_id AS source_id,
              d.page AS page,
              REPLACE(
                snippet(doc_chunks_fts, 0, '', '', '…', 18),
                COALESCE(d.section_title || ' ', ''),
                ''
              ) AS excerpt,
              bm25(doc_chunks_fts) AS score
            FROM doc_chunks AS d
            JOIN doc_chunks_fts ON doc_chunks_fts.rowid = d.rowid
            WHERE doc_chunks_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [query]

            if let s = source {
                sql += " AND d.source_id = ?"
                args.append(s)
            }

            sql += " ORDER BY score LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map {
                SnippetHit(
                    rowid: $0["rowid"],
                    sourceId: $0["source_id"],
                    page: $0["page"],
                    excerpt: $0["excerpt"],
                    bm25: $0["score"]
                )
            }
        }
    }
    
    func fetchNeighbors(sourceId: String, around rowid: Int64, expand: Int) throws -> [NeighborChunk] {
        try dbQueue.read { db in
            let prevRows = try Row.fetchAll(db, sql: """
                SELECT rowid, content, page
                FROM doc_chunks
                WHERE source_id = ? AND rowid < ?
                ORDER BY rowid DESC
                LIMIT ?
            """, arguments: [sourceId, rowid, expand]).reversed()

            let nextRows = try Row.fetchAll(db, sql: """
                SELECT rowid, content, page
                FROM doc_chunks
                WHERE source_id = ? AND rowid >= ?
                ORDER BY rowid ASC
                LIMIT ?
            """, arguments: [sourceId, rowid, expand + 1])

            let toChunk: (Row) -> NeighborChunk = { r in
                NeighborChunk(rowid: r["rowid"], text: r["content"], page: r["page"])
            }
            return prevRows.map(toChunk) + nextRows.map(toChunk)
        }
    }
    
    
    
}


internal struct DocChunkStore {
    let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    func insert(sourceId: String, page: Int?, content: String, sectionTitle: String? = nil, ftsContent: String? = nil) throws {
        try dbQueue.write { db in
            let id = UUID().uuidString
            try db.execute(sql: """
              INSERT INTO doc_chunks (id, source_id, page, content, section_title)
              VALUES (?, ?, ?, ?, ?)
            """, arguments: [id, sourceId, page, content, sectionTitle])

            try db.execute(sql: """
              INSERT INTO doc_chunks_fts(rowid, content, source_id, section_title)
              VALUES (
                (SELECT rowid FROM doc_chunks WHERE id = ?),
                ?, ?, ?
              )
            """, arguments: [id, ftsContent ?? content, sourceId, sectionTitle])
        }
    }

    func ftsSnippets(query: String, inSource source: String? = nil, limit: Int = 10) throws -> [Snippet] {
        try dbQueue.read { db in
            var sql = """
                SELECT d.source_id, d.page, snippet(doc_chunks_fts, 0, '', '', '…', 18) AS excerpt, bm25(doc_chunks_fts) AS score
                FROM doc_chunks AS d
                JOIN doc_chunks_fts ON doc_chunks_fts.rowid = d.rowid
                WHERE doc_chunks_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [query]

            if let s = source {
                sql += " AND (d.source_id = ? OR d.source_id LIKE ?)"
                args.append(contentsOf: [s, "\(s) p.%"])
            }

            sql += " ORDER BY score LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            
            return rows.map {
                Snippet(
                    sourceId: $0["source_id"],
                    page: $0["page"],
                    excerpt: $0["excerpt"],
                    score: $0["score"]
                )
            }
        }
    }


    func upsertSource(id: String, filePath: String, displayName: String, pages: Int?, chunks: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
              INSERT INTO sources (id, file_path, display_name, pages, chunks, imported_at)
              VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ','now'))
              ON CONFLICT(id) DO UPDATE SET
                file_path=excluded.file_path,
                display_name=excluded.display_name,
                pages=excluded.pages,
                chunks=excluded.chunks,
                imported_at=excluded.imported_at
            """, arguments: [id, filePath, displayName, pages, chunks])
        }
    }

    func listSources() throws -> [Source] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
              SELECT id, file_path, display_name, pages, chunks,
                     COALESCE(imported_at, strftime('%Y-%m-%dT%H:%M:%SZ','now')) AS imported_at
              FROM sources ORDER BY imported_at DESC
            """).map { row in
                Source(
                    id: row["id"], filePath: row["file_path"], displayName: row["display_name"],
                    pages: row["pages"], chunks: row["chunks"], importedAt: row["imported_at"]
                )
            }
        }
    }

    func deleteChunks(forSourceId base: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM doc_chunks WHERE source_id = ? OR source_id LIKE ?", arguments: [base, "\(base) p.%"])
            try db.execute(sql: "INSERT INTO doc_chunks_fts(doc_chunks_fts) VALUES('rebuild')")
        }
    }

    func deleteSource(id base: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM doc_chunks WHERE source_id LIKE ?", arguments: ["\(base) p.%"])
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [base])
            try db.execute(sql: "INSERT INTO doc_chunks_fts(doc_chunks_fts) VALUES('rebuild')")
        }
    }
}
