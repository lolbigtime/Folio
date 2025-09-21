//
//  FolioEngine.swift
//  Folio
//
//  Created by Tai Wong on 9/11/25.
//

import Foundation


public struct IndexingConfig: Sendable {
    public var useContextualPrefix = true
    public var contextFn: (@Sendable (_ doc: LoadedDocument, _ page: LoadedPage, _ chunk: String) async throws -> String)? = nil

    public init() {}
}

public struct FolioConfig {
    public var chunking = ChunkingConfig()
    public var indexing = IndexingConfig()
    public init() {}
}

public struct RetrievedPassage {
    public let sourceId: String
    public let startPage: Int?
    public let excerpt: String
    public let text: String
    public let bm25: Double
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
    
    
    @discardableResult
    public func ingestAsync(_ input: IngestInput, sourceId: String, config: FolioConfig = .init()) async throws -> (pages: Int, chunks: Int) {
        
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

            let key = store.cacheKey(sourceId: c.sourceId, page: c.page, chunk: c.text)
            var prefix = (try? store.getCachedPrefix(for: key)) ?? ""

            if config.indexing.useContextualPrefix && prefix.isEmpty {
                if let f = config.indexing.contextFn {
                    let raw = (try? await f(cleaned, pg, c.text)) ?? Contextualizer.prefix(doc: cleaned, page: pg, chunk: c.text)
                    
                    var line = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.count > 600 { line = String(line.prefix(600)) }
                    prefix = line.isEmpty ? Contextualizer.prefix(doc: cleaned, page: pg, chunk: c.text) : line

                    let meta = ["model": "user-provided", "rev": "v1", "chars": "\(prefix.count)"]
                    let metaJSON = (try? JSONSerialization.data(withJSONObject: meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    try? store.putCachedPrefix(key: key, value: prefix, metaJSON: metaJSON)
                } else {
                    prefix = Contextualizer.prefix(doc: cleaned, page: pg, chunk: c.text)
                }
            } else if !config.indexing.useContextualPrefix {
                prefix = ""
            }

            let augmented = prefix + c.text
            try store.insert(sourceId: c.sourceId, page: c.page, content: c.text, sectionTitle: prefix, ftsContent: augmented)
            inserted += 1
        }

        try? store.upsertSource(id: sourceId, filePath: doc.name, displayName: doc.name, pages: doc.pages.count, chunks: inserted)
        return (doc.pages.count, inserted)
    }
    
    @discardableResult
    public func searchWithContext(_ query: String, in sourceId: String? = nil, limit: Int = 5, expand: Int = 1) throws -> [RetrievedPassage] {
        precondition(limit > 0, "Limit needs to be greater than 0")
        precondition(expand >= 0, "Expand must be non-negative")
        
        let hits = try store.ftsHits(query: query, inSource: sourceId, limit: max(limit * 6, 60))
        
        var results: [RetrievedPassage] = []
        var usedRowids = Set<Int64>()
        
        for h in hits {
            guard !usedRowids.contains(h.rowid) else { continue }
            
            let window = try store.fetchNeighbors(sourceId: h.sourceId, around: h.rowid, expand: expand)
            guard !window.isEmpty else { continue }
            
            window.forEach { usedRowids.insert($0.rowid) }
            
            let mergedText = window.map(\.text).joined(separator: "\n\n")
            let startPage = window.first?.page
            
            results.append(RetrievedPassage(sourceId: h.sourceId, startPage: startPage, excerpt: h.excerpt, text: mergedText, bm25: h.bm25))
            if results.count >= limit { break }

        }
        
        return results
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


