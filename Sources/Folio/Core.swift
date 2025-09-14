//
//  Core.swift
//  Folio
//
//  Created by Tai Wong on 9/13/25.
//

import Foundation


///Common Data Types
public struct Chunk: Sendable, Hashable {
    public let id: String
    public let sourceId: String
    public let page: Int?
    public let text: String
    public let tags: Set<String>
    public init(id: String = UUID().uuidString, sourceId: String, page: Int?, text: String, tags: Set<String> = []) {
        self.id = id; self.sourceId = sourceId; self.page = page; self.text = text; self.tags = tags
    }
}

public struct LoadedPage: Sendable {
    public let index: Int
    public let text: String
    
    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

public struct LoadedDocument: Sendable {
    public let name: String
    public let pages: [LoadedPage]
    
    public init(name: String, pages: [LoadedPage]) {
        self.name = name
        self.pages = pages
    }
}

public enum IngestInput {
    case pdf(URL)
    case text(String, name: String?)
    case data(Data, uti: String, name: String?)
}

public struct ChunkingConfig: Sendable {
    public var maxTokensPerChunk = 650
    public var overlapTokens = 80
    public init() {}
    
}

///Extension Points
public protocol DocumentLoader {
    func load(_ input: IngestInput) throws -> LoadedDocument
}

public protocol Chunker {
    func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk]
}

