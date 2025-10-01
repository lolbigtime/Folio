// Tests/FolioTests/FolioSmokeTests.swift
import XCTest
@testable import Folio

final class FolioSmokeTests: XCTestCase {
    func testTextIngestAndSearch() throws {
        let folio = try FolioEngine.inMemory()
        _ = try folio.ingest(.text("hello world from folio", name: "note.txt"), sourceId: "T1")
        let hits = try folio.search("hello", in: "T1", limit: 1)
        XCTAssertFalse(hits.isEmpty)
    }

    func testNormalizeRemovesHyphenWraps() throws {
        let loader = TextDocumentLoader()
        let document = try loader.load(.text("multi-\nline\nre-entry", name: "mock.pdf"))

        guard let text = document.pages.first?.text else {
            XCTFail("Missing normalized text")
            return
        }

        XCTAssertEqual(text, "multiline\nre-entry")
    }
}
