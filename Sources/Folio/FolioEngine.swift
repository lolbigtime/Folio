//
//  FolioEngine.swift
//  Folio
//
//  Created by Tai Wong on 9/11/25.
//

import Foundation

public func mapPassagesToResults(_ passages: [RetrievedPassage], scoreFromBM25: (Double) -> Double = { $0 }) -> [RetrievedResult] {
    passages.map { p in
        RetrievedResult(
            sourceId: p.sourceId,
            startPage: p.startPage,
            excerpt: p.excerpt,
            text: p.text,
            bm25: p.bm25,
            cosine: nil,
            score: scoreFromBM25(p.bm25)
        )
    }
}

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

public struct RetrievedResult: Sendable {
    public let sourceId: String
    public let startPage: Int?
    public let excerpt: String
    public let text: String
    public let bm25: Double
    public let cosine: Double?
    public let score: Double
}

public struct DocumentFetch: Sendable {
    public let sourceId: String
    public let displayName: String
    public let startPage: Int?
    public let endPage: Int?
    public let text: String
    public let chunkIds: [String]
}

public final class FolioEngine {
    private let db: AppDatabase
    private let store:  DocChunkStore
    private let loaders: [DocumentLoader]
    private let chunker: Chunker
    private let embedder: Embedder?

    public convenience init(loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil, embedder: Embedder? = nil) throws {
        let url = try FolioEngine.defaultDatabaseURL()
        let useLoaders = loaders ?? [PDFDocumentLoader(), TextDocumentLoader()]
        let useChunker = chunker ?? UniversalChunker()

        try self.init(databaseURL: url, loaders: useLoaders, chunker: useChunker, embedder: embedder)
    }


    public convenience init(appGroup identifier: String, loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil, embedder: Embedder? = nil) throws {
        let url = try FolioEngine.appGroupDatabaseURL(identifier: identifier)
        let useLoaders = loaders ?? [PDFDocumentLoader(), TextDocumentLoader()]
        let useChunker = chunker ?? UniversalChunker()

        try self.init(databaseURL: url, loaders: useLoaders, chunker: useChunker, embedder: embedder)
    }

    public static func inMemory(loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil, embedder: Embedder? = nil) throws -> FolioEngine {
        let useLoaders = loaders ?? [PDFDocumentLoader(), TextDocumentLoader()]
        let useChunker = chunker ?? UniversalChunker()

        return try FolioEngine(databaseURL: URL(fileURLWithPath: ":memory:"), loaders: useLoaders, chunker: useChunker, embedder: embedder)
    }
    
    public init(databaseURL: URL, loaders: [DocumentLoader], chunker: Chunker, embedder: Embedder?) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        self.db = try AppDatabase(path: databaseURL.path)
        self.store = DocChunkStore(dbQueue: db.dbQueue)
        self.loaders = loaders
        self.chunker = chunker
        self.embedder = embedder
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
            let newChunk = try store.insertReturningIdentifiers(
                sourceId: c.sourceId,
                page: c.page,
                content: c.text,
                sectionTitle: prefix,
                ftsContent: augmented
            )

            inserted += 1
            if let embedder {
                let vec = try embedder.embed(augmented)

                try store.insertVector(chunkId: newChunk.chunkId, dim: vec.count, vector: vec)
            }
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

    public func fetchDocument(sourceId: String, startPage: Int? = nil, anchor: String? = nil, expand: Int = 2, maxChars: Int? = 8000) throws -> DocumentFetch {
        precondition(expand >= 0 && expand <= 8, "expand must be between 0 and 8")
        if let startPage {
            precondition(startPage >= 0, "startPage must be non-negative")
        }
        if let maxChars {
            precondition(maxChars > 0, "maxChars must be positive")
        }

        guard let source = try store.fetchSource(id: sourceId) else {
            throw NSError(domain: "Folio", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source not found"])
        }

        let trimmedAnchor = anchor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAnchor = trimmedAnchor.flatMap { $0.isEmpty ? nil : $0 }
        let anchorRowId = try normalizedAnchor.flatMap { try store.findAnchorRowid(sourceId: sourceId, anchor: $0) }

        let chunks: [DocChunkStore.NeighborChunk]
        if let rowid = anchorRowId {
            chunks = try store.fetchNeighbors(sourceId: sourceId, around: rowid, expand: expand)
        } else if let startPage {
            chunks = try store.fetchChunks(forSourceId: sourceId, startingFromPage: startPage)
        } else {
            chunks = try store.fetchAllChunks(forSourceId: sourceId)
        }

        guard !chunks.isEmpty else {
            return DocumentFetch(sourceId: sourceId, displayName: source.displayName, startPage: nil, endPage: nil, text: "", chunkIds: [])
        }

        let chunkIds = chunks.map(\.chunkId)
        let startPage = chunks.compactMap(\.page).min()
        let endPage = chunks.compactMap(\.page).max()

        var text = chunks.map(\.text).joined(separator: "\n\n")
        if let maxChars, text.count > maxChars {
            text = String(text.prefix(maxChars))
        }

        return DocumentFetch(
            sourceId: sourceId,
            displayName: source.displayName,
            startPage: startPage,
            endPage: endPage,
            text: text,
            chunkIds: chunkIds
        )
    }

    /// Computes embeddings for any chunks that are missing a vector and persists them for hybrid search fusion.
    /// Keeping BM25 and cosine in sync is critical so both scorers see identical chunk sets.
    /// - Parameters:
    ///   - sourceId: Optionally scope the work to a specific source hierarchy.
    ///   - batch: The number of chunks to embed per API call.
    public func backfillEmbeddings(for sourceId: String? = nil, batch: Int = 64) throws {
        guard let embedder else {
            throw NSError(domain: "Folio", code: 410, userInfo: [NSLocalizedDescriptionKey: "Embedder not configured"])
        }
        precondition(batch > 0, "batch must be positive")

        while true {
            let chunks = try store.fetchEmbeddableChunks(for: sourceId, limit: batch)
            if chunks.isEmpty { break }

            let embeddings = try embedder.embedBatch(chunks.map(\.text))
            guard embeddings.count == chunks.count else {
                throw NSError(domain: "Folio", code: 411, userInfo: [NSLocalizedDescriptionKey: "Embedding count mismatch"])
            }

            for (chunk, vector) in zip(chunks, embeddings) {
                try store.insertVector(chunkId: chunk.chunkId, dim: vector.count, vector: vector)
            }
        }
    }

    public func searchHybrid(_ query: String, in sourceId: String? = nil, limit: Int = 5, expand: Int = 1, wBM25: Double = 0.5) throws -> [RetrievedResult] {
        precondition(limit > 0 && expand >= 0, "invalid params")
        
        let hits = try store.ftsHits(query: query, inSource: sourceId, limit: max(limit * 6, 60))
        if hits.isEmpty { return [] }
        
        var cosByRow: [Int64: Double] = [:]
        if let embedder {
            let qv = try embedder.embed(query)
            let vrows = try store.fetchVectors(forRowids: hits.map { $0.rowid })
            
            func cosine(_ a: [Float], _ b: [Float]) -> Double {
                let n = min(a.count, b.count)
                var dot = 0.0, na = 0.0, nb = 0.0
                
                for i in 0..<n {
                    let x = Double(a[i]), y = Double(b[i])
                    dot += x*y
                    na += x*x
                    nb += y*y
                    
                }
                
                return (na == 0 || nb == 0) ? 0.0 : dot / (sqrt(na) * sqrt(nb))
            }
            
            for r in vrows {
                cosByRow[r.rowid] = cosine(qv, r.vec)
            }
        }
        
        let allBM = hits.map(\.bm25)
        
        struct Cand {
            let h: DocChunkStore.SnippetHit
            let fused: Double
            let cos: Double?
        }
        
        let ranked = hits.map { h -> Cand in
            let cos = cosByRow[h.rowid]
            let fused = RankFusion.fuse(bm25: allBM, bm25: h.bm25, cosine: cos, wBM25: wBM25)
            
            return Cand(h: h, fused: fused, cos: cos)
        }.sorted { $0.fused > $1.fused }
        
        var out: [RetrievedResult] = []
        var used = Set<Int64>()
        
        for c in ranked {
            guard !used.contains(c.h.rowid) else {
                continue
            }
            
            let window = try store.fetchNeighbors(sourceId: c.h.sourceId, around: c.h.rowid, expand: expand)
            guard !window.isEmpty else {
                continue
            }
            
            window.forEach { used.insert($0.rowid) }
            out.append(.init(sourceId: c.h.sourceId, startPage: window.first?.page, excerpt: c.h.excerpt, text: window.map(\.text).joined(separator: "\n\n"), bm25: c.h.bm25, cosine: c.cos, score: c.fused))
            
            if out.count >= limit {
                break
            }
        }
    
        return out
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


