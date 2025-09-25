# Folio

Folio is a zero-config retrieval engine for iOS and macOS.  
It ingests PDFs and text, strips headers/footers, chunks content, and indexes it into SQLite with **BM25 FTS5 search**.  

On top of this, Folio supports Anthropic-style **contextual retrieval**:  
- LLM-generated prefixes per chunk (using pluggable prompts)  
- Optional embeddings (e.g., EmbeddingGemma, LLaMA)  
- Rank fusion of BM25 + vectors  
- Neighbor expansion for coherent RAG passages  

---

## 🚀 Quick Start

### Basic BM25
```swift
import Folio

let folio = try FolioEngine()

try folio.ingest(.text("hello world from folio", name: "note.txt"), sourceId: "T1")

let hits = try folio.search("hello", in: "T1", limit: 5)
for h in hits {
    print("• \(h.sourceId): \(h.excerpt)")
}
```

---

### Contextual Prefixing with an LLM
```swift
var cfg = FolioConfig()
cfg.indexing.useContextualPrefix = true
cfg.indexing.contextFn = { doc, page, chunk in
    let ctx = ChunkContext(docName: doc.name,
                           pageIndex: page.index,
                           chunkText: chunk)
    let prompt = LLMPrefixPrompter.build(ctx)

    // Example: call your local LLaMA or remote endpoint
    let prefix = try await MyLLM.shared.complete(
        prompt: prompt,
        maxTokens: LLMPrefixPrompter.maxOutputTokens,
        stop: LLMPrefixPrompter.stop
    )
    return LLMPrefixPrompter.sanitize(prefix)
}

let folio = try FolioEngine()
let _ = try await folio.ingestAsync(.pdf(pdfURL), sourceId: "Doc1", config: cfg)
```

---

### Hybrid Retrieval (BM25 + Embeddings + Fusion)
```swift
let folio = try FolioEngine(embedder: GemmaEmbedder())

let results = try folio.searchWithContext(
    "transformer architecture",
    in: "Doc1",
    limit: 5,
    expand: 1
)

for r in results {
    print("• \(r.sourceId) p.\(r.startPage ?? 0): \(r.excerpt)")
    // r.text = merged window of neighboring chunks
}
```

---

### Prompt Templates
```swift
let ctx = ChunkContext(docName: "Paper",
                       pageIndex: 3,
                       sectionHeader: "Results",
                       chunkText: "The model achieved state-of-the-art...")
let prompt = LLMPrefixPrompter.build(ctx)
print(prompt)
```

Output → Anthropic-style instruction asking the LLM to return **one short line**.

---

## 📊 Pipeline Overview

```mermaid
flowchart TD
    A[PDF/Text Input] --> B[DocumentLoader]
    B --> C[HeaderFooterFilter]
    C --> D[Chunker]
    D --> E{Contextual Prefix?}
    E -- Yes --> F[LLM Prefix Generator (Anthropic-style prompt)]
    E -- No --> G[Raw Chunks]
    F --> H[Augmented Chunk (prefix+text)]
    G --> H
    H --> I[Embedder (Gemma/LLaMA) optional]
    H --> J[SQLite FTS5 BM25 Index]
    I --> K[Vector Store (doc_chunk_vectors)]
    J --> L[BM25 Search]
    K --> M[Vector Search]
    L --> N[Rank Fusion]
    M --> N
    N --> O[Neighbor Expansion]
    O --> P[Retrieved Passages]
```

---

## 📂 Schema

- `sources` — documents metadata  
- `doc_chunks` — content chunks (page, section_title, content)  
- `doc_chunks_fts` — FTS5 mirror (BM25)  
- `prefix_cache` — cached LLM prefixes  
- `doc_chunk_vectors` — optional embeddings  

---

## License
MIT
