//
//  PDFImporter.swift
//  Folio
//
//  Created by Tai Wong on 9/4/25.



import Foundation
import PDFKit

public struct PDFImporter {
    let store: DocChunkStore
    let config: FolioConfig

    public init(store: DocChunkStore, config: FolioConfig = .init()) {
        self.store = store
        self.config = config
    }

    public struct ImportSummary {
        public let sourceId: String
        public let pagesProcessed: Int
        public let chunksInserted: Int
        public init(sourceId: String, pagesProcessed: Int, chunksInserted: Int) {
            self.sourceId = sourceId
            self.pagesProcessed = pagesProcessed
            self.chunksInserted = chunksInserted
        }
    }

    public enum ImportError: LocalizedError {
        case loadFailed
        public var errorDescription: String? { "Failed to open PDF." }
    }

    @discardableResult
    public func importPDF(at url: URL, sourceId: String) throws -> ImportSummary {
        try? store.deleteChunks(forSourceId: sourceId)

        let loader = PDFDocumentLoader()
        let doc = try loader.load(.pdf(url))

        var chunkCfg = ChunkingConfig()
        chunkCfg.maxTokensPerChunk = config.chunking.maxTokensPerChunk
        chunkCfg.overlapTokens = config.chunking.overlapTokens

        let chunker = UniversalChunker()
        let chunks = try chunker.chunk(sourceId: sourceId, doc: doc, config: chunkCfg)

        var inserted = 0
        for c in chunks {
            try store.insert(sourceId: c.sourceId, page: c.page, content: c.text)
            inserted += 1
        }

        try? store.upsertSource(id: sourceId,
                                filePath: url.path,
                                displayName: doc.name,
                                pages: doc.pages.count,
                                chunks: inserted)

        return .init(sourceId: sourceId, pagesProcessed: doc.pages.count, chunksInserted: inserted)
    }

    @discardableResult
    public func importPDF(at url: URL) throws -> ImportSummary {
        try importPDF(at: url, sourceId: url.deletingPathExtension().lastPathComponent)
    }
}
