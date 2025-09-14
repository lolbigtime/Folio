# Folio

**Zero-config RAG + DB + Chunking** for iOS & macOS.  
Ingest PDFs or text, chunk generically, and query with fast **SQLite FTS5 (BM25)** — in a tiny, swappable architecture.

<p align="left">
  <img alt="SwiftPM" src="https://img.shields.io/badge/SwiftPM-ready-orange">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-iOS%2016%2B%20|%20macOS%2013%2B-blue">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-informational">
</p>

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration (Optional)](#configuration-optional)
- [Managing Sources](#managing-sources)
- [Architecture](#architecture)
- [Core Types & Protocols](#core-types--protocols)
- [Extending Folio](#extending-folio)
- [Schema](#schema)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [License](#license)

---

## Features

- **Zero setup**: `try FolioEngine()` picks a sane on-device DB path.
- **Loaders**: PDF (with Vision OCR fallback) & plain text.
- **Chunker**: universal sentence/line chunking with overlap & size controls.
- **Retrieval**: SQLite **FTS5** with **BM25** ranking + highlighted snippets.
- **Pluggable**: bring your own `DocumentLoader` / `Chunker`.
- **Environments**: in-memory mode for tests; App Group support for extensions.

---

## Installation

Add via **Swift Package Manager** (Xcode → *File* → *Add Packages…*)  
Point to your repo URL, then ensure the target processes resources:

```swift
// Package.swift (snippet)
.target(
  name: "Folio",
  dependencies: [
    .product(name: "GRDB", package: "GRDB.swift")
  ],
  resources: [.process("Resources")] // ships SQL migrations
)
```

---

## Quick Start

```swift
import Folio

// 1) Zero-config engine (DB in Application Support/Folio/folio.sqlite)
let folio = try FolioEngine()

// 2) Ingest a PDF
let (pages, chunks) = try folio.ingest(.pdf(pdfURL), sourceId: "MyDoc")
print("Ingested \(pages) pages → \(chunks) chunks")

// 3) Search (BM25)
let hits = try folio.search("introduction", in: "MyDoc", limit: 5)
for h in hits {
  print("• \(h.sourceId) p.\(h.page ?? 0): \(h.excerpt)")
}
```

**Also works with raw text:**
```swift
let _ = try folio.ingest(.text("Some notes here...", name: "notes.txt"),
                         sourceId: "MyNotes")
```

**App Group (extensions/shared containers):**
```swift
let folio = try FolioEngine(appGroup: "group.com.yourcompany.yourapp")
```

**In-memory (unit tests):**
```swift
let folio = try FolioEngine.inMemory()
```

---

## Configuration (Optional)

```swift
var cfg = FolioConfig()
cfg.chunking.maxTokensPerChunk = 650   // ~2.3–2.6k chars (≈ 3.6 chars/token)
cfg.chunking.overlapTokens   = 80

let _ = try folio.ingest(.pdf(pdfURL), sourceId: "DocA", config: cfg)
```

---

## Managing Sources

```swift
let sources = try folio.listSources()         // what's indexed
try folio.deleteSource("MyDoc")               // purge + FTS mirror rebuild
```

---

## Architecture

```
Input (.pdf / .text / …)
  → DocumentLoader   (PDFDocumentLoader, TextDocumentLoader, …)
  → LoadedDocument   (pages of normalized text)
  → Chunker          (UniversalChunker by default)
  → [Chunk]          (sourceId, page?, text)
  → Store            (SQLite + FTS5 mirror)
  → Search           (BM25 + snippets)
```

- **Engine** is tiny plumbing (zero domain terms).
- **Loaders** and **Chunkers** are swappable.

---

## Core Types & Protocols

```swift
public enum IngestInput {
  case pdf(URL)
  case text(String, name: String?)
  case data(Data, uti: String, name: String?) // future
}

public struct LoadedPage   { public let index: Int; public let text: String }
public struct LoadedDocument { public let name: String; public let pages: [LoadedPage] }

public protocol DocumentLoader {
  func load(_ input: IngestInput) throws -> LoadedDocument
}

public struct ChunkingConfig {
  public var maxTokensPerChunk = 650
  public var overlapTokens = 80
}

public protocol Chunker {
  func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk]
}

public struct Chunk {
  public let id: String
  public let sourceId: String
  public let page: Int?
  public let text: String
}

public struct Snippet {
  public let sourceId: String
  public let page: Int?
  public let excerpt: String
  public let score: Double
}
```

---

## Extending Folio

<details>
<summary><strong>Example: Markdown loader</strong></summary>

```swift
public struct MarkdownDocumentLoader: DocumentLoader {
  public init() {}
  public func load(_ input: IngestInput) throws -> LoadedDocument {
    guard case let .text(s, name) = input else {
      throw NSError(domain: "Folio", code: 402, userInfo: [NSLocalizedDescriptionKey: "Not markdown text"])
    }
    let plain = s
      .replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression) // drop code fences
      .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)        // drop stray HTML
    return LoadedDocument(name: name ?? "markdown", pages: [LoadedPage(index: 1, text: plain)])
  }
}

// Use:
let folio = try FolioEngine(
  loaders: [PDFDocumentLoader(), TextDocumentLoader(), MarkdownDocumentLoader()],
  chunker: UniversalChunker()
)
```
</details>

<details>
<summary><strong>Example: Paragraph chunker</strong></summary>

```swift
public struct ParagraphChunker: Chunker {
  public init() {}
  public func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] {
    let maxChars = Int(Double(config.maxTokensPerChunk) * 3.6)
    let overlap  = Int(Double(config.overlapTokens) * 3.6)
    var out: [Chunk] = []
    for p in doc.pages {
      for para in p.text.components(separatedBy: "\n\n") where !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        for piece in chunkParagraph(para, max: maxChars, overlap: overlap) {
          out.append(Chunk(id: UUID().uuidString, sourceId: sourceId, page: p.index, text: piece))
        }
      }
    }
    return out
  }
  private func chunkParagraph(_ text: String, max: Int, overlap: Int) -> [String] {
    var res:[String]=[]; var i=text.startIndex
    while i < text.endIndex {
      let j = text.index(i, offsetBy: max, limitedBy: text.endIndex) ?? text.endIndex
      var end = j; if j < text.endIndex, let sp = text[i..<j].lastIndex(of: " ") { end = sp }
      let s = text[i..<end].trimmingCharacters(in: .whitespacesAndNewlines); if !s.isEmpty { res.append(String(s)) }
      let adv = max(1, s.count - overlap); i = text.index(i, offsetBy: adv, limitedBy: text.endIndex) ?? text.endIndex
    }
    return res
  }
}
```
</details>

---

## Schema

**Tables (auto-migrated from `Resources/` on first run):**
```sql
-- sources
CREATE TABLE IF NOT EXISTS sources (
  id TEXT PRIMARY KEY,
  display_name TEXT,
  file_path TEXT,
  pages INTEGER,
  chunks INTEGER,
  imported_at TEXT DEFAULT CURRENT_TIMESTAMP
);

-- doc_chunks
CREATE TABLE IF NOT EXISTS doc_chunks (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  page INTEGER,
  content TEXT NOT NULL,
  section_title TEXT,
  FOREIGN KEY(source_id) REFERENCES sources(id)
);
```

**FTS5 mirror:**
```sql
CREATE VIRTUAL TABLE IF NOT EXISTS doc_chunks_fts USING fts5(
  content, source_id, section_title,
  content='doc_chunks', content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 2 tokenchars ''-_'''
);
```

---

## Troubleshooting

- **“No SQL migrations found in Resources”**  
  Ensure your package target has `resources: [.process("Resources")]` and includes  
  `001_core.sql`, `002_fts.sql`, `003_indexes.sql`.

- **FTS tokenizer error**  
  Keep the doubled quotes around `tokenchars` exactly as shown.

- **No search hits**  
  Verify you ingested with the same `sourceId` you’re filtering on; scanned PDFs rely on the Vision OCR fallback in `PDFDocumentLoader`.

- **Where is the database?**  
  Default: `Application Support/Folio/folio.sqlite`. Use the `appGroup:` init to share across extensions.

---

## Roadmap

- Markdown & HTML loaders  
- Header/footer de-dup filter for paged docs  
- Optional vector embeddings + hybrid retrieval  
- Context budgeter + answer synthesizer with citations

---

## License

MIT — see `LICENSE`.

---

### Minimal Example App (copy–paste)

```swift
import SwiftUI
import Folio

@main
struct DemoApp: App {
  var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
  @State var log = ""
  var body: some View {
    ScrollView { Text(log).textSelection(.enabled).padding() }
      .task {
        do {
          let folio = try FolioEngine()
          let pdfURL = Bundle.main.url(forResource: "sample", withExtension: "pdf")!
          let (_, chunks) = try folio.ingest(.pdf(pdfURL), sourceId: "Sample")
          let hits = try folio.search("introduction", in: "Sample", limit: 3)
          log = "Chunks: \(chunks)\n" + hits.map { "• p.\($0.page ?? 0): \($0.excerpt)" }.joined(separator: "\n")
        } catch { log = "Error: \(error)" }
      }
  }
}
```
