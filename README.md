Folio

Zero-config RAG + DB + Chunking for iOS & macOS.
Ingest PDFs or text, chunk generically, and query with fast SQLite FTS5 (BM25) — all in a tiny, swappable architecture.

✅ Zero setup: try FolioEngine() picks a sane DB path automatically

📄 Loaders: PDF (with Vision OCR fallback), plain text

✂️ Universal chunker: sentence/line splitting with overlap

🔎 Retrieval: SQLite FTS5 with BM25 ranking + highlighted snippets

🧩 Pluggable: bring your own DocumentLoader / Chunker

🧪 In-memory mode for tests; App Group support for extensions

Platforms: iOS 16+, macOS 13+ (Swift 5.9+). Uses GRDB under the hood.

Installation (Swift Package Manager)

Xcode → File → Add Packages…
Enter your repo URL (e.g. https://github.com/you/Folio) and add the Folio product to your app target.

Make sure your package target processes resources:

.target(
  name: "Folio",
  dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
  resources: [.process("Resources")]   // ships SQL migrations
)

Quick Start
import Folio

let folio = try FolioEngine()                           // zero-config DB in Application Support
let (pages, chunks) = try folio.ingest(.pdf(pdfURL),    // ingest a PDF
                                       sourceId: "MyDoc")

let hits = try folio.search("introduction", in: "MyDoc", limit: 5)
for h in hits {
  print("• \(h.sourceId) p.\(h.page ?? 0): \(h.excerpt)")
}

Also works with raw text
let _ = try folio.ingest(.text("Some notes here...", name: "note.txt"),
                         sourceId: "MyNotes")

App Group (for extensions / shared containers)
let folio = try FolioEngine(appGroup: "group.com.yourcompany.yourapp")

In-memory (great for unit tests)
let folio = try FolioEngine.inMemory()

Configuration (optional)
var cfg = FolioConfig()
cfg.chunking.maxTokensPerChunk = 650   // ~2.3–2.6k chars
cfg.chunking.overlapTokens   = 80

let _ = try folio.ingest(.pdf(pdfURL), sourceId: "DocA", config: cfg)

Managing Sources
// List what’s indexed
let sources = try folio.listSources()

// Delete one source and rebuild FTS mirror
try folio.deleteSource("MyDoc")

Architecture (tiny + swappable)
Input (.pdf / .text / …)
  → DocumentLoader  (PDFDocumentLoader, TextDocumentLoader, …)
  → LoadedDocument  (pages of normalized text)
  → Chunker         (UniversalChunker by default)
  → [Chunk]         (sourceId, page?, text)
  → Store           (SQLite + FTS5)
  → Search          (BM25 + snippets)

Core types & protocols
public enum IngestInput { case pdf(URL), text(String, name: String?), data(Data, uti: String, name: String?) }

public struct LoadedDocument { public let name: String; public let pages: [LoadedPage] }
public struct LoadedPage { public let index: Int; public let text: String }

public protocol DocumentLoader { func load(_ input: IngestInput) throws -> LoadedDocument }
public protocol Chunker { func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] }

public struct Chunk { public let id, sourceId: String; public let page: Int?; public let text: String }
public struct Snippet { public let sourceId: String; public let page: Int?; public let excerpt: String; public let score: Double }

Extend Folio (add loaders/chunkers)
Example: Markdown loader
public struct MarkdownDocumentLoader: DocumentLoader {
  public func load(_ input: IngestInput) throws -> LoadedDocument {
    guard case let .text(s, name) = input else { throw NSError() }
    let plain = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
                 .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    return LoadedDocument(name: name ?? "markdown", pages: [LoadedPage(index: 1, text: plain)])
  }
}

// Use it:
let folio = try FolioEngine(loaders: [PDFDocumentLoader(), TextDocumentLoader(), MarkdownDocumentLoader()],
                            chunker: UniversalChunker())

Example: Custom chunker (paragraphs)
public struct ParagraphChunker: Chunker {
  public func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] {
    let maxChars = Int(Double(config.maxTokensPerChunk) * 3.6)
    var out: [Chunk] = []
    for p in doc.pages {
      for para in p.text.components(separatedBy: "\n\n") where !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        for piece in para.chunked(max: maxChars, overlap: Int(Double(config.overlapTokens) * 3.6)) {
          out.append(Chunk(sourceId: sourceId, page: p.index, text: piece))
        }
      }
    }
    return out
  }
}
private extension String {
  func chunked(max: Int, overlap: Int) -> [String] {
    var res:[String]=[]; var i=startIndex
    while i < endIndex {
      let j = index(i, offsetBy: max, limitedBy: endIndex) ?? endIndex
      var end = j; if j < endIndex, let sp = self[i..<j].lastIndex(of: " ") { end = sp }
      let s = self[i..<end].trimmingCharacters(in: .whitespacesAndNewlines); if !s.isEmpty { res.append(String(s)) }
      let adv = max(1, s.count - overlap); i = index(i, offsetBy: adv, limitedBy: endIndex) ?? endIndex
    }
    return res
  }
}

Storage schema (auto-migrated)

Folio ships SQL migrations in Resources/ and applies them automatically.

-- sources
id TEXT PRIMARY KEY,
display_name TEXT,
file_path TEXT,
pages INTEGER,
chunks INTEGER,
imported_at TEXT DEFAULT CURRENT_TIMESTAMP

-- doc_chunks
id TEXT PRIMARY KEY,
source_id TEXT NOT NULL,
page INTEGER,
content TEXT NOT NULL,
section_title TEXT


FTS5 mirror:

CREATE VIRTUAL TABLE doc_chunks_fts USING fts5(
  content, source_id, section_title,
  content='doc_chunks', content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 2 tokenchars ''-_'''
);

Troubleshooting

“No SQL migrations found in Resources”
Ensure your target has resources: [.process("Resources")] and the files exist:
001_core.sql, 002_fts.sql, 003_indexes.sql.

FTS tokenizer error
Keep the doubled quotes around tokenchars exactly as shown above.

No search hits
Make sure you search with the right sourceId. For scanned PDFs, OCR fallback runs inside PDFDocumentLoader (requires Vision on device/simulator).

Where is the database?
Default path: Application Support/Folio/folio.sqlite. Use appGroup: init to share across extensions.

Roadmap

Markdown & HTML loaders

Header/Footer de-dup filter for paged docs

Optional vector embeddings + hybrid retrieval

Built-in context budgeter + answer synthesizer with citations

License

MIT (or your choice). Add a LICENSE file.

Minimal Example (copy–paste)
import Folio
import SwiftUI

@main
struct DemoApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
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
        } catch {
          log = "Error: \(error)"
        }
      }
  }
}
