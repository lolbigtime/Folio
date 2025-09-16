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
        }
    }
}

