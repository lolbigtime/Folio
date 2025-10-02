#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(iOS 18.0, macOS 15.0, *)
public actor FoundationModelsPrefixGenerator {
    public struct Configuration: Sendable {
        public var instructions: String
        public var locale: String?
        public var options: GenerationOptions

        public init(
            instructions: String = FoundationModelsPrefixGenerator.defaultInstructions,
            locale: String? = nil,
            options: GenerationOptions? = nil
        ) {
            var resolved = options ?? GenerationOptions()
            if resolved.maximumResponseTokens == nil {
                resolved.maximumResponseTokens = LLMPrefixPrompter.maxOutputTokens
            }
            self.instructions = instructions
            self.locale = locale
            self.options = resolved
        }
    }

    public static let defaultInstructions: String = """
    You generate short retrieval prefixes for document chunks.
    Return a single concise line (no newlines) that helps a search system
    understand how the chunk fits within the wider document.
    Keep it specific, 5-12 words, and prefer nouns over verbs.
    Do not add trailing punctuation or numbering.
    """

    private let session: LanguageModelSession
    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.session = LanguageModelSession(instructions: configuration.instructions)
    }

    public func prefix(
        for doc: LoadedDocument,
        page: LoadedPage,
        chunk: String,
        context: ChunkContext? = nil
    ) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw UnavailableError.state(SystemLanguageModel.default.availability)
        }

        let header = page.text
            .split(separator: "\n")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.range(of: #"^page\s*\d+$"#, options: .regularExpression) == nil }

        let ctx = context ?? ChunkContext(
            docName: doc.name,
            pageIndex: page.index,
            sectionHeader: header,
            chunkText: chunk,
            localeHint: configuration.locale
        )

        let prompt = LLMPrefixPrompter.build(ctx)
        let raw = try await session.respond(to: prompt, options: configuration.options)
        let sanitized = LLMPrefixPrompter.sanitize(raw)

        guard !sanitized.isEmpty else {
            throw GenerationError.empty
        }

        return sanitized
    }

    public func prefixWithFallback(
        for doc: LoadedDocument,
        page: LoadedPage,
        chunk: String,
        context: ChunkContext? = nil
    ) async -> String {
        do {
            return try await prefix(for: doc, page: page, chunk: chunk, context: context)
        } catch {
            return Contextualizer.prefix(doc: doc, page: page, chunk: chunk)
        }
    }

    public func makeContextFunction() -> @Sendable (LoadedDocument, LoadedPage, String) async throws -> String {
        { doc, page, chunk in
            try await self.prefix(for: doc, page: page, chunk: chunk)
        }
    }

    public nonisolated func makeFallbackContextFunction() -> @Sendable (LoadedDocument, LoadedPage, String) async -> String {
        { doc, page, chunk in
            await self.prefixWithFallback(for: doc, page: page, chunk: chunk)
        }
    }

    public enum GenerationError: Error, Sendable {
        case empty
    }

    public enum UnavailableError: Error, Sendable {
        case state(SystemLanguageModel.Availability)
    }
}

@available(iOS 18.0, macOS 15.0, *)
public extension IndexingConfig {
    static func foundationModelPrefixes(
        configuration: FoundationModelsPrefixGenerator.Configuration = .init()
    ) -> IndexingConfig {
        var config = IndexingConfig()
        config.useContextualPrefix = true
        let generator = FoundationModelsPrefixGenerator(configuration: configuration)
        config.contextFn = { doc, page, chunk in
            try await generator.prefix(for: doc, page: page, chunk: chunk)
        }
        return config
    }

    mutating func useFoundationModelPrefixes(
        configuration: FoundationModelsPrefixGenerator.Configuration = .init()
    ) {
        useContextualPrefix = true
        let generator = FoundationModelsPrefixGenerator(configuration: configuration)
        contextFn = { doc, page, chunk in
            try await generator.prefix(for: doc, page: page, chunk: chunk)
        }
    }
}
#endif
