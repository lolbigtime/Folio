//
//  HeaderFooterFilter.swift
//  Folio
//
//  Created by Tai Wong on 9/15/25.
//

import Foundation

struct HeaderFooterFilter {
    static func strip(_  doc: LoadedDocument) -> LoadedDocument {
        guard doc.pages.count >= 3 else {
            return doc
        }
        
        var firstCounts: [String: Int] = [:]
        var lastCounts: [String: Int] = [:]
        
        for p in doc.pages {
            let lines = normalizedLines(p.text)
            if let f = lines.first { firstCounts[f, default: 0] += 1 }
            if let l = lines.last { lastCounts[l, default: 0] += 1 }
        }
        
        let frequentFirst = Set(firstCounts.sorted { $0.value > $1.value }.prefix(2).map { $0.key })
        let frequentLast = Set(lastCounts.sorted { $0.value > $1.value }.prefix(2).map { $0.key })
        
        let newPages = doc.pages.map { page -> LoadedPage in
            let kept = normalizedLines(page.text)
                .drop(while: { frequentFirst.contains($0) })
                .reversed()
                .drop(while: { frequentLast.contains($0) })
                .reversed()
                .joined(separator: "\n")
            
            return LoadedPage(index: page.index, text: kept)
        }
        
        return LoadedDocument(name: doc.name, pages: newPages)
    }
    
    private static func normalizedLines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
