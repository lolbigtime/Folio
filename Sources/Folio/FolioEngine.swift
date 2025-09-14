//
//  FolioEngine.swift
//  Folio
//
//  Created by Tai Wong on 9/11/25.
//

import Foundation

public struct FolioConfig {
    public var chunking = ChunkingConfig()
    public init() {}
}

public final class FolioEngine {
    private let db: AppDatabase
    private let store:  DocChunkStore
    private let loaders: [DocumentLoader]
    private let chunker: Chunker
    
    public convenience init(loaders: [DocumentLoader] = [PDFDocumentLoader(), TextDocumentLoader()], chunker: Chunker = UniversalChunker()) throws {
        let url = try FolioEngine.defaultDatabaseURL()
        try self.init(databaseURL: url, loaders: loaders, chunker: chunker)
    }
    
    public convenience init(appGroup identifier: String, loaders: [DocumentLoader] = [PDFDocumentLoader(), TextDocumentLoader()], chunker: Chunker = UniversalChunker()) throws {
        let url = try FolioEngine.appGroupDatabaseURL(identifier: identifier)
        try self.init(databaseURL: url, loaders: loaders, chunker: chunker)
    }
    
    public static func inMemory(loaders: [DocumentLoader] = [PDFDocumentLoader(), TextDocumentLoader()], chunker: Chunker = UniversalChunker()) throws -> FolioEngine {
        return try FolioEngine(databaseURL: URL(fileURLWithPath: ":memory:"), loaders: loaders, chunker: chunker)
    }
    
    public init(databaseURL: URL, loaders: [DocumentLoader], chunker: Chunker) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        self.db = try AppDatabase(path: databaseURL.path)
        self.store = DocChunkStore(dbQueue: db.dbQueue)
        self.loaders = loaders
        self.chunker = chunker
    }
    
    //Ingest any supported input with caller chosen sourceID
    @discardableResult
    public func ingest(_ input: IngestInput, sourceId: String, config: FolioConfig = .init()) throws -> (pages: Int, chunks: Int) {
        guard let loader = loaders.first(where: { canLoad($0, input: input) }) else {
            throw NSError(domain: "Folio", code: 400, userInfo: [NSLocalizedDescriptionKey: "No loader for input"])
        }
        let doc = try loader.load(input)
        try? store.deleteChunks(forSourceId: sourceId)

        let chunks = try chunker.chunk(sourceId: sourceId, doc: doc, config: config.chunking)
        var inserted = 0
        for c in chunks {
            try store.insert(sourceId: c.sourceId, page: c.page, content: c.text)
            inserted += 1
        }

        try? store.upsertSource(id: sourceId, filePath: doc.name, displayName: doc.name, pages: doc.pages.count, chunks: inserted)
        return (doc.pages.count, inserted)
    }

    
    public func search(_ query: String, in sourceId: String? = nil, limit: Int = 10) throws -> [Snippet] {
        try store.ftsSnippets(query: query, inSource: sourceId, limit: limit)
    }
    
    public func deleteSource(_ sourceId: String) throws {
        try store.deleteChunks(forSourceId: sourceId)
    }
    
    public func listSources() throws -> [Source] {
        try store.listSources()
    }
    
    private func canLoad(_ loader: DocumentLoader, input: IngestInput) -> Bool {
        switch input {
            case .pdf:  return loader is PDFDocumentLoader
            case .text: return loader is TextDocumentLoader
            case .data: return false // add a Data loader later
        }
    }
    
    private static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Folio", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        
        return dir.appendingPathComponent("folio.sqlite")
    }

    private static func appGroupDatabaseURL(identifier: String) throws -> URL {
        let fm = FileManager.default
        
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw NSError(domain: "Folio", code: 401, userInfo: [NSLocalizedDescriptionKey: "App Group not found: \(identifier)"])
        }
        let dir = container.appendingPathComponent("Folio", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        
        return dir.appendingPathComponent("folio.sqlite")
    }
}


