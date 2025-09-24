import Foundation

public enum ChunkKind: Sendable {
    case prose
    case code
    case table
    case figure
    case list
}

public struct ChunkContext: Sendable {
    public let docName: String?
    public let pageIndex: Int?
    public let sectionHeader: String?
    public let leftContext: String?
    public let chunkText: String
    public let rightContext: String?
    public let kind: ChunkKind
    public let localeHint: String?

    public init(docName: String? = nil, pageIndex: Int? = nil, sectionHeader: String? = nil, leftContext: String? = nil, chunkText: String, rightContext: String? = nil, kind: ChunkKind = .prose, localeHint: String? = nil) {
        self.docName = docName
        self.pageIndex = pageIndex
        self.sectionHeader = sectionHeader
        self.leftContext = leftContext
        self.chunkText = chunkText
        self.rightContext = rightContext
        self.kind = kind
        self.localeHint = localeHint
    }
}

public enum LLMPrefixPrompter {
    public static let maxOutputTokens: Int = 80
    public static let stop: [String] = ["\n\n", "\n", "###", "---", "```"]

    public static func build(_ ctx: ChunkContext) -> String {
        let name   = ctx.docName ?? "Document"
        let page   = ctx.pageIndex.map { "p.\($0)" } ?? "p.?"
        let header = (ctx.sectionHeader?.isEmpty == false) ? ctx.sectionHeader! : "—"
        let left   = (ctx.leftContext ?? "").prefix(800)
        let right  = (ctx.rightContext ?? "").prefix(800)
        let chunk  = ctx.chunkText.prefix(1600)
        let locale = ctx.localeHint ?? "en"

        return """
        <document>
        \(name) — \(header) — \(page)
        </document>

        Here is the chunk we want to situate within the whole document:

        <left>
        \(left)
        </left>

        <chunk>
        \(chunk)
        </chunk>

        <right>
        \(right)
        </right>

        Please give a short, succinct context to situate this chunk within the overall document for the purposes of improving search retrieval.

        Requirements:
        - Return only ONE short line (<= \(maxOutputTokens) tokens).
        - No explanations, no reasoning, no extra text.
        - Output must be a single line (no newlines).
        - Prefer concrete nouns (e.g., "Evaluation setup — metrics and datasets").
        - Keep to ~5–12 words; no trailing punctuation.
        - Language: \(locale).

        Your single line:
        """
    }

    public static func sanitize(_ s: String, maxChars: Int = 600) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ")
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxChars { t = String(t.prefix(maxChars)) }
        if t.lowercased().hasPrefix("answer:") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}
