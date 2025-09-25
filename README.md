# Folio

Folio is a zero‑config retrieval engine for iOS and macOS.  
It ingests PDFs and text, strips headers/footers, chunks content, and indexes it into SQLite with **BM25 (FTS5)**.  

It also supports **Anthropic‑style contextual retrieval**:
- LLM‑generated **one‑line prefixes** per chunk (pluggable prompts)
- Optional **contextual embeddings** (e.g., EmbeddingGemma, LLaMA)
- **Hybrid search**: BM25 + vectors with rank fusion
- **Neighbor expansion**: join ± adjacent chunks for coherent RAG passages

---

## Installation (Swift Package Manager)

1. In Xcode: **File → Add Packages…**  
2. Enter your repo URL and add the **Folio** package.  
3. Target settings → **Build Phases → Copy Bundle Resources**: ensure the `Resources/Migrations/*.sql` files are included (SPM’s `.process` resources).

**Package.swift snippet (if consuming manually):**
```swift
.dependencies: [
    .package(url: "https://github.com/your-org/folio.git", .upToNextMinor(from: "0.1.0"))
]
```

---

## Pipeline Overview

```mermaid
flowchart TD
    A[PDF or Text Input] --> B[DocumentLoader]
    B --> C[HeaderFooterFilter]
    C --> D[Chunker]
    D --> E{Contextual Prefix?}
    E -- Yes --> F[LLM Prefix Generator]
    E -- No --> G[Raw Chunks]
    F --> H[Augmented Chunk: prefix + text]
    G --> H
    H --> I[Embedder (optional)]
    H --> J[SQLite FTS5: BM25 Index]
    I --> K[Vector Store]
    J --> L[BM25 Search]
    K --> M[Vector Scoring]
    L --> N[Rank Fusion]
    M --> N
    N --> O[Neighbor Expansion]
    O --> P[Retrieved Passages]
```

> If you see a Mermaid render error on GitHub: make sure the block starts with ```` ```mermaid ```` exactly and that labels don’t contain unmatched parentheses.

---

## Quick Start

### Basic BM25 only
```swift
import Folio

let folio = try FolioEngine()

try folio.ingest(.text("hello world from folio", name: "note.txt"), sourceId: "T1")

let hits = try folio.search("hello", in: "T1", limit: 5)
for h in hits {
    print("• \(h.sourceId): \(h.excerpt)  [score=\(h.score)]")
}
```

### Contextual prefixes with an LLM (Anthropic‑style)
```swift
var cfg = FolioConfig()
cfg.indexing.useContextualPrefix = true
cfg.indexing.contextFn = { doc, page, chunk in
    let prompt = LLMPrefixPrompter.build(ChunkContext(
        docName: doc.name,
        pageIndex: page.index,
        sectionHeader: page.header,
        chunkText: chunk
    ))
    let raw = try await MyLocalLLM.generate(
        prompt: prompt,
        maxTokens: LLMPrefixPrompter.maxOutputTokens,
        temperature: 0.2,
        stop: LLMPrefixPrompter.stop
    )
    return LLMPrefixPrompter.sanitize(raw)
}

let folio = try FolioEngine()
_ = try await folio.ingestAsync(.pdf(pdfURL), sourceId: "Doc1", config: cfg)
```

### Hybrid retrieval (BM25 + vectors + fusion + expand)
```swift
// Provide an embedder (e.g., EmbeddingGemma) at init
let engine = try FolioEngine(
    databaseURL: dbURL,
    loaders: [PDFDocumentLoader(), TextDocumentLoader()],
    chunker: UniversalChunker(),
    embedder: EmbeddingGemmaEmbedder(dim: 256) // your wrapper
)

let passages = try engine.searchHybrid("optimizer settings", in: "Doc1", limit: 5, expand: 1)
for p in passages {
    print("• \(p.sourceId) p.\(p.startPage ?? 0)  [bm25=\(p.bm25), cos=\(p.cosine ?? .nan), score=\(p.score)]")
    print(p.text)
}
```

---

## Public API (high‑level)

```swift
// Engine
public final class FolioEngine {
    public convenience init() throws
    public convenience init(appGroup identifier: String, loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil) throws
    public static func inMemory(loaders: [DocumentLoader]? = nil, chunker: Chunker? = nil) throws -> FolioEngine
    public init(databaseURL: URL, loaders: [DocumentLoader], chunker: Chunker, embedder: Embedder?) throws

    @discardableResult
    public func ingest(_ input: IngestInput, sourceId: String, config: FolioConfig = .init()) throws -> (pages: Int, chunks: Int)

    @discardableResult
    public func ingestAsync(_ input: IngestInput, sourceId: String, config: FolioConfig = .init()) async throws -> (pages: Int, chunks: Int)

    public func search(_ query: String, in sourceId: String? = nil, limit: Int = 10) throws -> [Snippet]
    public func searchWithContext(_ query: String, in sourceId: String? = nil, limit: Int = 5, expand: Int = 1) throws -> [RetrievedPassage]
    public func searchHybrid(_ query: String, in sourceId: String? = nil, limit: Int = 5, expand: Int = 1, wBM25: Double = 0.5) throws -> [RetrievedResult]

    public func deleteSource(_ sourceId: String) throws
    public func listSources() throws -> [Source]
}
```

### Config types
```swift
public struct FolioConfig {
    public var chunking = ChunkingConfig()
    public var indexing = IndexingConfig()
    public init() {}
}

public struct IndexingConfig: Sendable {
    public var useContextualPrefix = true
    public var contextFn: (@Sendable (_ doc: LoadedDocument, _ page: LoadedPage, _ chunk: String) async throws -> String)? = nil
    public init() {}
}
```

### Prompt templates
```swift
let ctx = ChunkContext(docName: doc.name, pageIndex: page.index, sectionHeader: page.header, chunkText: chunk)
let prompt = LLMPrefixPrompter.build(ctx)
// Use MyLocalLLM.generate(prompt:..., maxTokens:..., stop: LLMPrefixPrompter.stop)
```

---

## Migrations & Schema

Migrations live in `Resources/Migrations/` and are processed by SPM. Ensure they’re included as **processed resources**.

- `001_core.sql` — `sources`, `doc_chunks`  
- `002_fts.sql` — `doc_chunks_fts` (FTS5 mirror; use `bm25(doc_chunks_fts)` and `snippet(...)`)  
- `003_indexes.sql` — helpful indexes  
- `004_prefix_cache.sql` — `prefix_cache` (LLM prefix memoization)  
- `005_embeddings.sql` — `doc_chunk_vectors(rowid, dim, vec BLOB)`

**Notes**
- `section_title` in `doc_chunks` stores the prefix; FTS content receives `prefix + chunk`.
- For BM25 snippets without prefix, use the store’s `ftsHits` which strips it from `snippet(...)` display.
- If you ever add a `position` column, prefer `(source_id, position)` for neighbor ordering over `rowid`.

---

## Embedders

Implement the `Embedder` protocol:

```swift
public protocol Embedder: Sendable {
    func embed(_ text: String) throws -> [Float]
    func embedBatch(_ texts: [String]) throws -> [[Float]]
}
```

**Recommendation**: embed **prefix + chunk** (contextual embeddings). Store vectors via `ingestAsync` which uses `insertReturningRowid` → `insertVector` automatically when `embedder` is provided.

---

## Testing (smoke)

- Ingest simple text, search for a term → non‑empty.  
- With prefixes enabled, verify displayed snippets don’t contain the prefix.  
- With vectors present, verify `searchHybrid` reorders results plausibly.

---

## License

MIT
