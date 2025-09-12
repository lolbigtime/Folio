//
//  PDFImporter.swift
//  ConnectorsKit
//
//  Created by Tai Wong on 9/4/25.
//  Updated: layout-aware chunking with grade-scale/schedule preservation
//

import Foundation
import PDFKit
import Vision
import DataKit
import Models

public struct PDFImporter {
    let store: DocChunkStore

    public init(store: DocChunkStore) {
        self.store = store
    }

    public struct ImportSummary {
        public let baseName: String
        public let pagesProcessed: Int
        public let chunksInserted: Int

        public init(baseName: String, pagesProcessed: Int, chunksInserted: Int) {
            self.baseName = baseName
            self.pagesProcessed = pagesProcessed
            self.chunksInserted = chunksInserted
        }
    }

    public enum ImportError: LocalizedError {
        case loadFailed
        public var errorDescription: String? { "Failed to open PDF." }
    }

    // MARK: - Tunables

    /// Target token budget per chunk (approx; we convert to chars via *4)
    private let maxTokens = 900
    /// Overlap tokens between adjacent chunks
    private let overlapTokens = 120
    /// Allow a little spill when packing consecutive schedule blocks to avoid splitting weekly tables
    private let scheduleSlackTokens = 120

    // Heuristics for visual grouping
    private let yTol: CGFloat = 0.008       // merge words → line (baseline similarity)
    private let yGapTol: CGFloat = 0.02     // merge lines → block (vertical gap)
    private let xAlignTol: CGFloat = 0.02   // left alignment tolerance

    // MARK: - Public

    @discardableResult
    public func importPDF(at url: URL, courseCode: String?) throws -> ImportSummary {
        guard let doc = PDFDocument(url: url) else { throw ImportError.loadFailed }

        let baseName = url.deletingPathExtension().lastPathComponent
        var inserted = 0
        try? store.deleteChunks(forSourceId: baseName)

        // 1) Extract layout-aware blocks (PDFKit text first; Vision OCR fallback)
        let blocks = try extractBlocks(from: doc)

        // 2) Pack into chunks respecting “do-not-split” sections (grade scale / schedule / table)
        let chunks = pack(blocks: blocks,
                          maxTokens: maxTokens,
                          overlapTokens: overlapTokens,
                          scheduleSlackTokens: scheduleSlackTokens)

        // 3) Insert into your store
        for (i, c) in chunks.enumerated() {
            // Decide representative page: first page spanned (1-based)
            let startPage = (c.pageSpans.first?.page ?? 0) + 1
            // Keep sourceId consistent with delete key so future imports wipe old rows clean
            try store.insert(
                sourceId: baseName,
                courseCode: courseCode,
                page: startPage,
                content: c.text
            )
            inserted += 1
        }

        return .init(baseName: baseName, pagesProcessed: doc.pageCount, chunksInserted: inserted)
    }
}

// MARK: - Private: Types

private enum BlockKind { case gradeScale, schedule, tableish, header, paragraph, list, unknown }

private struct TextSpan {
    let text: String
    let bbox: CGRect    // normalized 0..1 in page coords (origin bottom-left)
    let pageIndex: Int
}

private struct Block {
    var lines: [TextSpan]
    var unionBox: CGRect
    var pageIndex: Int
    var kind: BlockKind
}

private struct PackedChunk {
    let text: String
    let pageSpans: [(page: Int, box: CGRect)]
    let approxTokens: Int
    let tags: Set<String>
}

// MARK: - Private: Core pipeline

private extension PDFImporter {

    // Token estimate (~4 chars/token for Llama-like models)
    func toks(_ s: String) -> Int { max(1, s.count / 4) }
    func tokenCapToChars(_ tokens: Int) -> Int { max(200, tokens * 4) }

    func extractBlocks(from pdf: PDFDocument) throws -> [Block] {
        var all: [Block] = []
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }

            // Prefer born-digital text (PDFKit) for fewer OCR errors
            if let pageText = page.string, !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Full range of the page's text
                let nsLen = (pageText as NSString).length
                let fullRange = NSRange(location: 0, length: nsLen)

                if let fullSel = page.selection(for: fullRange) {
                    // Break the selection into line selections
                    let lineSelections: [PDFSelection] = fullSel.selectionsByLine()

                    let pb = page.bounds(for: .mediaBox)
                    let spans: [TextSpan] = lineSelections.compactMap { sel in
                        let raw = sel.string ?? ""
                        let text = normalize(raw)
                        guard !text.isEmpty else { return nil }
                        let r = sel.bounds(for: page)         // page coords
                        // normalize to 0..1, origin bottom-left
                        let norm = CGRect(x: r.minX / pb.width,
                                          y: r.minY / pb.height,
                                          width: r.width / pb.width,
                                          height: r.height / pb.height)
                        return TextSpan(text: text, bbox: norm, pageIndex: pageIndex)
                    }

                    let lines = mergeIntoLines(fromSpans: spans, pageIndex: pageIndex) // safe no-op if already lines
                    var blocks = groupLinesIntoBlocks(lines: lines)
                    blocks = blocks.map { classify(block: $0) }
                    all.append(contentsOf: blocks)
                    continue
                }
            }


            // Fallback: Vision OCR
            let image = page.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
            guard let cg = image.cgImage else { continue }

            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try handler.perform([req])
            let observations = req.results ?? []

            let spans = observations.compactMap { obs -> TextSpan? in
                guard let best = obs.topCandidates(1).first else { return nil }
                let text = normalize(best.string)
                guard !text.isEmpty else { return nil }
                return TextSpan(text: text, bbox: obs.boundingBox, pageIndex: pageIndex)
            }

            let lines = mergeIntoLines(fromSpans: spans, pageIndex: pageIndex)
            var blocks = groupLinesIntoBlocks(lines: lines)
            blocks = blocks.map { classify(block: $0) }
            all.append(contentsOf: blocks)
        }
        return all
    }

    // Merge words → lines by similar baseline (midY)
    func mergeIntoLines(fromSpans spans: [TextSpan], pageIndex: Int) -> [TextSpan] {
        guard !spans.isEmpty else { return [] }
        let sorted = spans.sorted { $0.bbox.midY > $1.bbox.midY } // top→down (Vision/PDFKit origin bottom-left)
        var out: [TextSpan] = []
        var bucket: [TextSpan] = []

        func flush() {
            guard !bucket.isEmpty else { return }
            let lineText = bucket.sorted { $0.bbox.minX < $1.bbox.minX }.map(\.text).joined(separator: " ")
            let union = bucket.dropFirst().reduce(bucket[0].bbox) { $0.union($1.bbox) }
            out.append(TextSpan(text: lineText, bbox: union, pageIndex: pageIndex))
            bucket.removeAll()
        }

        for s in sorted {
            if let last = bucket.last, abs(s.bbox.midY - last.bbox.midY) > yTol { flush() }
            bucket.append(s)
        }
        flush()
        return out
    }

    // Lines → visual blocks (vertical gap OR left-edge alignment)
    func groupLinesIntoBlocks(lines: [TextSpan]) -> [Block] {
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted { $0.bbox.maxY > $1.bbox.maxY } // top→down
        var blocks: [Block] = []
        var cur: [TextSpan] = []

        func flush() {
            guard !cur.isEmpty else { return }
            let union = cur.dropFirst().reduce(cur[0].bbox) { $0.union($1.bbox) }
            blocks.append(Block(lines: cur, unionBox: union, pageIndex: cur[0].pageIndex, kind: .unknown))
            cur.removeAll()
        }

        for (i, line) in sorted.enumerated() {
            if i == 0 { cur = [line]; continue }
            let prev = sorted[i - 1]
            let yGap = prev.bbox.minY - line.bbox.maxY
            let xAligned = abs(prev.bbox.minX - line.bbox.minX) < xAlignTol
            if yGap < yGapTol || xAligned { cur.append(line) } else { flush(); cur = [line] }
        }
        flush()
        return blocks
    }

    // ---- Regexes (compiled once) ----
    var gradePercentRE: NSRegularExpression {
        // A 93–100 % etc.
        try! NSRegularExpression(pattern: #"(?im)\b([ABCDF][+-]?)\s+(\d{1,2}(?:\.\d+)?)\s*[-–]\s*(\d{1,2}(?:\.\d+)?)\s*%?"#)
    }
    var gradePointsRE: NSRegularExpression {
        // A 920–1000 (points-based scales)
        try! NSRegularExpression(pattern: #"(?im)^\s*([ABCDF][+-]?)\s*[=:]?\s*(?:<\s*)?([\d,]{2,4})(?:\s*[-–]\s*([\d,]{2,4}))?\b"#)
    }
    var weightRE: NSRegularExpression {
        // Exam 25%, Quiz 10% ...
        try! NSRegularExpression(pattern: #"(?im)\b(quiz|exam|midterm|final|homework|project|lab|participation)\b[^\n]{0,40}(\d{1,3}(?:\.\d+)?)\s*%?"#)
    }
    var schedWordRE: NSRegularExpression {
        // schedule-ish words
        try! NSRegularExpression(pattern: #"(?im)\b(week|wk\.?|lecture|lab|recitation|topic|reading|due|deadline|milestone|quiz|exam|schedule|office hours|help session)\b"#)
    }
    var schedDateRE: NSRegularExpression { try! NSRegularExpression(pattern: #"(?im)\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b"#) }
    var schedMonthRE: NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?im)\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b"#)
    }
    var weekdayRE: NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?im)\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)\b"#)
    }

    func match(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }
    func countMatches(_ re: NSRegularExpression, _ s: String) -> Int {
        re.matches(in: s, range: NSRange(location: 0, length: s.utf16.count)).count
    }

    // Classify blocks: schedule / gradeScale / table-ish / header / paragraph
    func classify(block: Block) -> Block {
        let text = block.lines.map(\.text).joined(separator: "\n")
        let first = block.lines.first?.text ?? ""
        let firstLower = first.lowercased()
        let looksHeader = first.uppercased() == first || first.hasSuffix(":")
        let headerIsSchedule = firstLower.contains("schedule") || firstLower.contains("class meeting schedule") || firstLower.contains("office hours")

        let hasGrade = match(gradePointsRE, text) || match(gradePercentRE, text)
        let hasWeight = match(weightRE, text)

        let hasSchedWord = match(schedWordRE, text)
        let hasDate = match(schedDateRE, text)
        let hasMonth = match(schedMonthRE, text)
        let hasWeekday = match(weekdayRE, text)

        let dateLineCount = block.lines.filter { match(schedDateRE, $0.text) }.count
        let weekdayLineCount = block.lines.filter { match(weekdayRE, $0.text) }.count
        let weekNCount = countMatches(try! NSRegularExpression(pattern: #"(?im)\bweek\s*\d+\b|^\s*wk\.?\s*\d+\b"#), text)

        var kind: BlockKind = .paragraph

        var looksSchedule = false
        if headerIsSchedule { looksSchedule = true }
        if hasSchedWord && (hasDate || hasMonth || hasWeekday) { looksSchedule = true }
        if (dateLineCount + weekdayLineCount) >= 2 { looksSchedule = true }
        if weekNCount >= 1 { looksSchedule = true }

        if looksSchedule { kind = .schedule }
        else if hasGrade { kind = .gradeScale }
        else if hasWeight { kind = .tableish }
        else if looksHeader { kind = .header }
        else { kind = .paragraph }

        return Block(lines: block.lines, unionBox: block.unionBox, pageIndex: block.pageIndex, kind: kind)
    }

    // Pack blocks → chunks with do-not-split for critical kinds and small schedule overflow
    func pack(blocks: [Block], maxTokens: Int, overlapTokens: Int, scheduleSlackTokens: Int) -> [PackedChunk] {
        let maxChars = tokenCapToChars(maxTokens)
        let overlapChars = tokenCapToChars(overlapTokens)
        let scheduleSlackChars = tokenCapToChars(min(scheduleSlackTokens, overlapTokens))

        func tags(for b: Block, text: String) -> Set<String> {
            var t = Set<String>()
            switch b.kind {
            case .gradeScale: t.formUnion(["grading", "scale"])
            case .schedule:   t.insert("schedule")
            case .tableish:   t.insert("table")
            case .header:     t.insert("header")
            default: break
            }
            // fallback: tag schedule if cues present even if not classified
            if t.isEmpty && looksSchedule(text) { t.insert("schedule") }
            // quick extra tags (helpful for retrieval later if you add metadata store)
            if text.range(of: #"(?i)\bexam\b|\bCBTF\b|\bfinal exam\b"#, options: .regularExpression) != nil {
                t.insert("exam")
            }
            if text.range(of: #"(?i)\battendance\b"#, options: .regularExpression) != nil { t.insert("attendance") }
            return t
        }

        func looksSchedule(_ s: String) -> Bool {
            (match(schedWordRE, s) && (match(schedDateRE, s) || match(schedMonthRE, s) || match(weekdayRE, s)))
        }

        let critical: Set<BlockKind> = [.gradeScale, .schedule, .tableish]

        var chunks: [PackedChunk] = []
        var buf = ""
        var spans: [(Int, CGRect)] = []
        var bufChars = 0
        var bufTags = Set<String>()

        func flush() {
            let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(PackedChunk(text: trimmed,
                                      pageSpans: spans,
                                      approxTokens: toks(trimmed),
                                      tags: bufTags))
            buf = ""; spans.removeAll(); bufChars = 0; bufTags.removeAll()
        }

        for b in blocks {
            let text = b.lines.map(\.text).joined(separator: "\n")
            let tChars = text.count
            var tg = tags(for: b, text: text)

            if critical.contains(b.kind) && tChars > maxChars {
                // keep huge critical block intact as a special chunk
                flush()
                chunks.append(PackedChunk(text: text,
                                          pageSpans: [(b.pageIndex, b.unionBox)],
                                          approxTokens: toks(text),
                                          tags: tg))
                continue
            }

            if bufChars + tChars > maxChars {
                let nextIsSchedy = (b.kind == .schedule) || looksSchedule(text)
                let inSchedRun = bufTags.contains("schedule")
                let over = bufChars + tChars - maxChars
                if inSchedRun && nextIsSchedy && over <= scheduleSlackChars {
                    // allow small overflow to keep schedule rows together
                } else {
                    flush()
                }
            }

            if !buf.isEmpty { buf += "\n" }
            buf += text
            spans.append((b.pageIndex, b.unionBox))
            bufChars += tChars
            bufTags.formUnion(tg)
        }
        flush()

        // Add small overlap from previous chunk tail; trim if exceeding (max + overlap)
        guard overlapChars > 0, chunks.count > 1 else { return chunks }
        var out: [PackedChunk] = []
        for i in 0..<chunks.count {
            if i == 0 { out.append(chunks[i]); continue }
            let prevTail = takeLastChars(chunks[i - 1].text, charCount: overlapChars)
            var merged = prevTail + "\n" + chunks[i].text
            let hardCap = maxChars + overlapChars
            if merged.count > hardCap {
                let need = merged.count - hardCap
                let trimmedTail = String(prevTail.dropFirst(min(prevTail.count, need + 16)))
                merged = trimmedTail + "\n" + chunks[i].text
            }
            out.append(PackedChunk(text: merged,
                                   pageSpans: chunks[i].pageSpans,
                                   approxTokens: toks(merged),
                                   tags: chunks[i].tags))
        }
        return out
    }
}

// MARK: - Utils

private func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
     .trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension PDFImporter {
    func takeLastChars(_ s: String, charCount: Int) -> String {
        let n = max(0, charCount)
        return String(s.suffix(n))
    }
}
