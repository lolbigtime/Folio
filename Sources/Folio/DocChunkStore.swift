//
//  DocChunkStore.swift
//  DataKit
//
//  Created by Tai Wong on 9/2/25.
//

import Foundation
import GRDB

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

public struct DocChunkStore {
    let dbQueue: DatabaseQueue
    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func insert(sourceId: String, page: Int?, content: String, sectionTitle: String? = nil) throws {
        try dbQueue.write { db in
            let id = UUID().uuidString
            try db.execute(sql: """
              INSERT INTO doc_chunks (id, source_id, page, content, section_title)
              VALUES (?, ?, ?, ?, ?)
            """, arguments: [id, sourceId, page, content, sectionTitle])

            try db.execute(sql: """
              INSERT INTO doc_chunks_fts(rowid, content, source_id, section_title)
              SELECT rowid, content, source_id, section_title
              FROM doc_chunks WHERE id = ?
            """, arguments: [id])
        }
    }

    public func ftsSnippets(query: String, inSource source: String? = nil, limit: Int = 10) throws -> [Snippet] {
        try dbQueue.read { db in
            var whereSQL = "f MATCH ?"
            var args: [DatabaseValueConvertible] = [query]
            if let s = source {
                whereSQL += " AND (d.source_id = ? OR d.source_id LIKE ?)"
                args.append(contentsOf: [s, "\(s) p.%"])
            }
            let rows = try Row.fetchAll(db, sql: """
              SELECT d.source_id, d.page,
                     snippet(doc_chunks_fts, 0, '', '', '…', 18) AS excerpt,
                     bm25(f) AS score
              FROM doc_chunks AS d
              JOIN doc_chunks_fts AS f ON f.rowid = d.rowid
              WHERE \(whereSQL)
              ORDER BY score
              LIMIT ?
            """, arguments: StatementArguments(args + [limit]))
            return rows.map { Snippet(sourceId: $0["source_id"], page: $0["page"], excerpt: $0["excerpt"], score: $0["score"]) }
        }
    }

    public func upsertSource(id: String, filePath: String, displayName: String, pages: Int?, chunks: Int) throws {
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

    public func listSources() throws -> [Source] {
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

    public func deleteChunks(forSourceId base: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM doc_chunks WHERE source_id = ? OR source_id LIKE ?", arguments: [base, "\(base) p.%"])
            try db.execute(sql: "INSERT INTO doc_chunks_fts(doc_chunks_fts) VALUES('rebuild')")
        }
    }

    public func deleteSource(id base: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM doc_chunks WHERE source_id LIKE ?", arguments: ["\(base) p.%"])
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [base])
            try db.execute(sql: "INSERT INTO doc_chunks_fts(doc_chunks_fts) VALUES('rebuild')")
        }
    }
}
