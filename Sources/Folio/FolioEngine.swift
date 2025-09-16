//
//  FolioEngine.swift
//  Folio
//
//  Created by Tai Wong on 9/11/25.
//

import Foundation


public struct IndexingConfig: Sendable {
    public var useContextualPrefix = true
    public var contextFn: (@Sendable (_ doc: LoadedDocument, _ page: LoadedPage, _ chunk: String) -> String)? = nil

    public init() {}
}

public struct FolioConfig {
    public var chunking = ChunkingConfig()
    public var indexing = IndexingConfig()
    public init() {}
}

public final class FolioEngine {
    private let db: AppDatabase
    private let store:  DocChunkStore
    private let loaders: [DocumentLoader]
    private let chunker: Chunker
    
    public convenience init(loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil) throws {
        let url = try FolioEngine.defaultDatabaseURL()
        let useLoaders = loaders ?? [PDFDocumentLoader(), TextDocumentLoader()]
        let useChunker = chunker ?? UniversalChunker()
        
        try self.init(databaseURL: url, loaders: useLoaders, chunker: useChunker)
    }
    
    
    public convenience init(appGroup identifier: String, loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil) throws {
        let url = try FolioEngine.appGroupDatabaseURL(identifier: identifier)
        let useLoaders = loaders ?? [PDFDocumentLoader(), TextDocumentLoader()]
        let useChunker = chunker ?? UniversalChunker()
        
        try self.init(databaseURL: url, loaders: useLoaders, chunker: useChunker)
    }
    
    public static func inMemory(loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil) throws -> FolioEngine {
        let useLoaders = loaders ?? [PDFDocumentLoader(), TextDocumentLoader()]
        let useChunker = chunker ?? UniversalChunker()
        
        return try FolioEngine(databaseURL: URL(fileURLWithPath: ":memory:"), loaders: useLoaders, chunker: useChunker)
    }
    
    public init(databaseURL: URL, loaders: [DocumentLoader], chunker: Chunker) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
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
        let cleaned = HeaderFooterFilter.strip(doc)

        try? store.deleteChunks(forSourceId: sourceId)
        try? store.upsertSource(id: sourceId, filePath: doc.name, displayName: doc.name, pages: doc.pages.count, chunks: 0)

        let pieces = try chunker.chunk(sourceId: sourceId, doc: cleaned, config: config.chunking)

        
        var inserted = 0
        for c in pieces {
            
            let pg = c.page.flatMap { idx in cleaned.pages.first { $0.index == idx } } ?? cleaned.pages.first!
            let prefix = config.indexing.useContextualPrefix ? Contextualizer.prefix(doc: cleaned, page: pg, chunk: c.text) : ""
            
            let augmented = prefix + c.text
            
            try store.insert(sourceId: c.sourceId, page: c.page, content: c.text, sectionTitle: prefix, ftsContent: augmented)
            
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
    
    internal static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Folio", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        
        return dir.appendingPathComponent("folio.sqlite")
    }

    internal static func appGroupDatabaseURL(identifier: String) throws -> URL {
        let fm = FileManager.default
        
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw NSError(domain: "Folio", code: 401, userInfo: [NSLocalizedDescriptionKey: "App Group not found: \(identifier)"])
        }
        let dir = container.appendingPathComponent("Folio", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        
        return dir.appendingPathComponent("folio.sqlite")
    }
}


