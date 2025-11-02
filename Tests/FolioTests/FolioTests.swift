// Tests/FolioTests/FolioSmokeTests.swift
import XCTest
import GRDB
@testable import Folio

final class FolioSmokeTests: XCTestCase {
    func testTextIngestAndSearch() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("hello world from folio", name: "note.txt"), sourceId: "T1")
        let hits = try folio.search("hello", in: "T1", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }

    func testNormalizeRemovesHyphenWraps() throws {
        let loader = TextDocumentLoader()
        let document = try loader.load(.text("multi-\nline\nre-entry", name: "mock.pdf"))

        guard let text = document.pages.first?.text else {
            XCTFail("Missing normalized text")
            return
        }

        XCTAssertEqual(text, "multiline\nre-entry")
    }

    func testNormalizeDropsObjectReplacementCharacters() throws {
        let loader = TextDocumentLoader()
        let document = try loader.load(.text("\u{FFFC}hello\u{FFFC}", name: "placeholder.pdf"))

        XCTAssertEqual(document.pages.first?.text, "hello")
    }

    func testNeedsOCRDetectsPlaceholderOnlyText() {
        XCTAssertTrue(needsOCR(forExtractedText: "\u{FFFC}\u{FFFC}"))
        XCTAssertTrue(needsOCR(forExtractedText: "   \n\t"))
        let sparseTable = String(repeating: "|  |  |", count: 40) + "A"
        XCTAssertTrue(needsOCR(forExtractedText: sparseTable))
        XCTAssertFalse(needsOCR(forExtractedText: "alpha"))
        XCTAssertFalse(needsOCR(forExtractedText: "1234"))
    }

    func testFetchDocumentWithAnchorAndLimits() throws {
        struct StubChunker: Chunker {
            func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] {
                [
                    Chunk(sourceId: sourceId, page: 0, text: "alpha beta gamma"),
                    Chunk(sourceId: sourceId, page: 0, text: "delta epsilon zeta"),
                    Chunk(sourceId: sourceId, page: 1, text: "eta theta iota")
                ]
            }
        }

        let engine = try FolioEngine.inMemory(chunker: StubChunker())
        _ = try engine.ingest(.text("unused", name: "note.txt"), sourceId: "Doc1")

        let full = try engine.fetchDocument(sourceId: "Doc1")
        XCTAssertEqual(full.chunkIds.count, 3)
        XCTAssertEqual(full.displayName, "note.txt")
        XCTAssertEqual(full.startPage, 0)
        XCTAssertEqual(full.endPage, 1)
        XCTAssertTrue(full.text.contains("alpha beta gamma"))
        XCTAssertTrue(full.text.contains("eta theta iota"))

        let anchor = try engine.fetchDocument(sourceId: "Doc1", anchor: "epsilon", expand: 1)
        XCTAssertEqual(anchor.chunkIds.count, 3)
        XCTAssertTrue(anchor.text.contains("delta epsilon zeta"))
        XCTAssertEqual(anchor.startPage, 0)
        XCTAssertEqual(anchor.endPage, 1)

        let fromPage = try engine.fetchDocument(sourceId: "Doc1", startPage: 1)
        XCTAssertEqual(fromPage.chunkIds.count, 1)
        XCTAssertEqual(fromPage.startPage, 1)
        XCTAssertEqual(fromPage.endPage, 1)
        XCTAssertTrue(fromPage.text.contains("eta theta iota"))

        let missing = try engine.fetchDocument(sourceId: "Doc1", startPage: 1, anchor: "omega")
        XCTAssertEqual(missing.chunkIds.count, 1)
        XCTAssertEqual(missing.startPage, 1)

        let truncated = try engine.fetchDocument(sourceId: "Doc1", maxChars: 20)
        XCTAssertLessThanOrEqual(truncated.text.count, 20)
    }

    func testBackfillEmbeddingsMatchesIngestWithPrefix() async throws {
        struct SingleChunkChunker: Chunker {
            let text: String

            func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] {
                [Chunk(sourceId: sourceId, page: doc.pages.first?.index, text: text)]
            }
        }

        final class RecordingEmbedder: Embedder, @unchecked Sendable {
            private var lock = NSLock()
            private(set) var embedCalls: [String] = []
            private(set) var embedBatchCalls: [[String]] = []

            func embed(_ text: String) throws -> [Float] {
                lock.lock()
                embedCalls.append(text)
                lock.unlock()
                return Self.vector(for: text)
            }

            func embedBatch(_ texts: [String]) throws -> [[Float]] {
                lock.lock()
                embedBatchCalls.append(texts)
                lock.unlock()
                return texts.map(Self.vector(for:))
            }

            private static func vector(for text: String) -> [Float] {
                text.unicodeScalars.map { Float($0.value % 97) / 97.0 }
            }
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")

        let embedder = RecordingEmbedder()
        let chunkBody = "Body paragraph content."
        let chunker = SingleChunkChunker(text: chunkBody)
        let engine = try FolioEngine(databaseURL: tmpURL, loaders: [TextDocumentLoader()], chunker: chunker, embedder: embedder)

        var config = FolioConfig()
        config.indexing.useContextualPrefix = true

        _ = try await engine.ingestAsync(.text("Intro\n\(chunkBody)", name: "Doc.pdf"), sourceId: "Doc1", config: config)

        XCTAssertEqual(embedder.embedCalls.count, 1)
        guard let ingestText = embedder.embedCalls.first else {
            XCTFail("Missing ingest embed call")
            return
        }

        XCTAssertTrue(ingestText.hasPrefix("[Doc.pdf"))
        XCTAssertTrue(ingestText.hasSuffix(chunkBody))
        XCTAssertNotEqual(ingestText, chunkBody)

        let dbQueue = try DatabaseQueue(path: tmpURL.path)

        let stored: (chunkId: String, vector: [Float])? = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT chunk_id, vec FROM doc_chunk_vectors LIMIT 1").map { row in
                let chunkId: String = row["chunk_id"]
                let data: Data = row["vec"]
                var array = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
                _ = array.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                return (chunkId, array)
            }
        }

        guard let initial = stored else {
            XCTFail("No stored vector found")
            return
        }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM doc_chunk_vectors")
        }

        try engine.backfillEmbeddings(for: "Doc1")

        XCTAssertEqual(embedder.embedBatchCalls.count, 1)
        XCTAssertEqual(embedder.embedBatchCalls.first?.first, ingestText)

        let after: (chunkId: String, vector: [Float])? = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT chunk_id, vec FROM doc_chunk_vectors LIMIT 1").map { row in
                let chunkId: String = row["chunk_id"]
                let data: Data = row["vec"]
                var array = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
                _ = array.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                return (chunkId, array)
            }
        }

        guard let reembedded = after else {
            XCTFail("No vector persisted after backfill")
            return
        }

        XCTAssertEqual(reembedded.chunkId, initial.chunkId)
        XCTAssertEqual(reembedded.vector, initial.vector)

        try? FileManager.default.removeItem(at: tmpURL)
    func testCustomLoaderIsInvokedWhenRegistered() throws {
        final class StubLoader: DocumentLoader {
            var loadCallCount = 0

            func supports(_ input: IngestInput) -> Bool {
                if case let .data(_, uti, _) = input {
                    return uti == "com.example.custom"
                }
                return false
            }

            func load(_ input: IngestInput) throws -> LoadedDocument {
                loadCallCount += 1

                guard case let .data(data, _, name) = input else {
                    throw NSError(domain: "Folio", code: 499, userInfo: [NSLocalizedDescriptionKey: "Unsupported input"])
                }

                let text = String(data: data, encoding: .utf8) ?? ""
                let page = LoadedPage(index: 0, text: text)
                return LoadedDocument(name: name ?? "custom", pages: [page])
            }
        }

        struct PassthroughChunker: Chunker {
            func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] {
                doc.pages.map { page in
                    Chunk(sourceId: sourceId, page: page.index, text: page.text)
                }
            }
        }

        let loader = StubLoader()
        let engine = try FolioEngine.inMemory(loaders: [loader], chunker: PassthroughChunker())
        let input = IngestInput.data(Data("hello folio".utf8), uti: "com.example.custom", name: "custom.bin")

        _ = try engine.ingest(input, sourceId: "Custom")

        XCTAssertEqual(loader.loadCallCount, 1)

        let hits = try engine.search("hello", in: "Custom", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    func testDeleteSourceRemovesSource() throws {
        let engine = try FolioEngine.inMemory()
        _ = try engine.ingest(.text("hello world", name: "note.txt"), sourceId: "Doc1")

        XCTAssertEqual(try engine.listSources().count, 1)

        try engine.deleteSource("Doc1")

        XCTAssertTrue(try engine.listSources().isEmpty)
    }
}
