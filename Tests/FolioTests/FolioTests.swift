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
}
