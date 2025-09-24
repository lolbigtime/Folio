//
//  Embedder.swift
//  Folio
//
//  Created by Tai Wong on 9/20/25.
//

import Foundation

public protocol Embedder: Sendable {
    func embed(_ text: String) throws -> [Float]
    func embedBatch(_ texts: [String]) throws -> [[Float]]
}

public extension Embedder {
    func embedBatch(_ texts: [String]) throws -> [[Float]] { try texts.map(embed) }
}
