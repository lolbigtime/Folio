//
//  UniversalChunker.swift
//  Folio
//
//  Created by Tai Wong on 9/13/25.
//


import Foundation
import NaturalLanguage

public struct UniversalChunker: Chunker {
    public init() {}
    public func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] {
        let maxChars = max(200, Int(Double(config.maxTokensPerChunk) * 3.6))
        let overlapChars = max(0, Int(Double(config.overlapTokens) * 3.6))

        var out: [Chunk] = []
        for page in doc.pages {
            let units = chooseUnits(page.text)
            var buf = ""
            func flush() {
                let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(Chunk(sourceId: sourceId, page: page.index, text: trimmed)) }
                buf.removeAll(keepingCapacity: true)
            }
            for u in units {
                if buf.isEmpty { buf = u; continue }
                if (buf.count + 1 + u.count) > maxChars {
                    flush()
                    if overlapChars > 0, let last = out.last {
                        let carry = String(last.text.suffix(overlapChars))
                        buf = (carry.isEmpty ? "" : carry + "\n") + u
                        if buf.count > maxChars { buf = u }
                    } else { buf = u }
                } else {
                    buf += (looksTableish(page.text) ? "\n" : " ") + u
                }
            }
            if !buf.isEmpty { flush() }
        }
        return out
    }
}

private func chooseUnits(_ text: String) -> [String] {
    if looksTableish(text) { return splitLines(text) }
    return splitSentences(text)
}
private func splitSentences(_ text: String) -> [String] {
    var out: [String] = []; let tok = NLTokenizer(unit: .sentence); tok.string = text
    tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
        let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }; return true
    }
    return out
}
private func splitLines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private let tableHintRE = try! NSRegularExpression(pattern: #"(?i)[\t\|]|(\S+\s{2,}\S+)"#)
private func looksTableish(_ s: String) -> Bool {
    tableHintRE.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
}
