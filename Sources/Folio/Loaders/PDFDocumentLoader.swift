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
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            var text = (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                #if canImport(Vision)
                let image = p.thumbnail(of: CGSize(width: 2000, height: 2000), for: .mediaBox)
                if let cg = image.cgImage {
                    let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate
                    let handler = VNImageRequestHandler(cgImage: cg, options: [:]); try? handler.perform([req])
                    text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }
                #endif
            }
            pages.append(.init(index: i+1, text: normalize(text)))
        }
        return LoadedDocument(name: url.lastPathComponent, pages: pages)
    }
}

internal struct TextDocumentLoader: DocumentLoader {
    init() {}
    func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .text(s, name) = input else {
            throw NSError(domain: "Folio", code: 402, userInfo: [NSLocalizedDescriptionKey: "Not text"])
        }
        return LoadedDocument(name: name ?? "text", pages: [.init(index: 1, text: normalize(s))])
    }
}

private func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}
