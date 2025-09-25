//
//  File.swift
//  Folio
//
//  Created by Tai Wong on 9/13/25.
//

import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif

internal struct PDFDocumentLoader: DocumentLoader {
    init() {}

    func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .pdf(url) = input, let doc = PDFDocument(url: url) else {
            throw NSError(domain: "Folio", code: 401, userInfo: [NSLocalizedDescriptionKey: "PDF open failed"])
        }

        var pages: [LoadedPage] = []
        pages.reserveCapacity(doc.pageCount)

        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }

            var text = extractText(from: page)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                #if canImport(Vision)
                text = (try? performOCR(on: page)) ?? text
                #endif
            }

            pages.append(.init(index: index, text: normalize(text)))
        }

        return LoadedDocument(name: url.lastPathComponent, pages: pages)
    }

    private func extractText(from page: PDFPage) -> String {
        // Using the attributed string keeps layout-driven newlines so code blocks/tables survive chunking.
        let attributed = page.attributedString ?? NSAttributedString(string: page.string ?? "")
        let raw = attributed.string.replacingOccurrences(of: "\u{00AD}", with: "")
        return raw
    }

    #if canImport(Vision)
    /// Falls back to Vision OCR so image-only PDFs still produce searchable text.
    private func performOCR(on page: PDFPage) throws -> String {
        guard let image = render(page: page, maxDimension: 2048) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .flatMap { result in result.topCandidates(1).map(\.string) }
            .joined(separator: "\n")
    }

    /// Rasterizes a PDF page with bounded dimensions to avoid excessive memory usage during OCR.
    private func render(page: PDFPage, maxDimension: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 && bounds.height > 0 else { return nil }

        let longest = max(bounds.width, bounds.height)
        let ratio = longest > 0 ? maxDimension / longest : 1
        let scale: CGFloat
        if longest >= maxDimension {
            scale = max(ratio, 0.25)
        } else {
            scale = min(max(ratio, 1), 4)
        }
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }
    #endif
}

internal struct TextDocumentLoader: DocumentLoader {
    init() {}

    func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .text(s, name) = input else {
            throw NSError(domain: "Folio", code: 402, userInfo: [NSLocalizedDescriptionKey: "Not text"])
        }

        // Page indices begin at 0 to match PDFs and keep neighbor expansion aligned across loaders.
        return LoadedDocument(name: name ?? "text", pages: [.init(index: 0, text: normalize(s))])
    }
}

/// Normalizes document text for consistent indexing while preserving layout-critical whitespace.
/// - Note: This performs Unicode NFKC so visually identical glyphs share the same code points
///   (improves matching), strips control characters except `\n` and `\t` to avoid invisible tokens,
///   and canonicalizes all newlines to `\n` so pagination and neighbor expansion stay aligned.
///   It intentionally *does not* trim or collapse internal whitespace to keep code blocks and tables intact.
private func normalize(_ s: String) -> String {
    var normalized = s.precomposedStringWithCompatibilityMapping
    normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
    normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
    normalized = normalized.replacingOccurrences(of: "\u{2028}", with: "\n")
    normalized = normalized.replacingOccurrences(of: "\u{2029}", with: "\n")

    let allowed: Set<UnicodeScalar> = ["\n", "\t"]
    let view = normalized.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
        if CharacterSet.controlCharacters.contains(scalar) {
            return allowed.contains(scalar) ? scalar : nil
        }
        return scalar
    }

    return String(String.UnicodeScalarView(view))
}
