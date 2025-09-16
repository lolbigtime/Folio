//
//  Contextualizer.swift
//  Folio
//
//  Created by Tai Wong on 9/15/25.
//

import Foundation

public enum Contextualizer {
        
    public static func prefix(doc: LoadedDocument, page: LoadedPage, chunk: String, contextFn: (@Sendable (_ doc: LoadedDocument, _ page: LoadedPage, _ chunk: String) -> String)? = nil) -> String {
        
        if let f = contextFn {
            return f(doc, page, chunk)
        }
        
        let header = page.text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && $0.range(of: #"^page\s*\d+$"#, options: .regularExpression) == nil }
        
        let parts = [doc.name, "p.\(page.index)", header ?? ""].filter { !$0.isEmpty }
        
        return "[" + parts.joined(separator: " · ") + "] - "
        
    }
    
}
