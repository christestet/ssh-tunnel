import CoreGraphics
import XCTest
@testable import SSHTunnelKit

/// Unit coverage for the wrapping math behind the menu-bar port pills
/// (`PortPillFlow`). The row-breaking logic is off-by-one prone exactly at the
/// `maxWidth` boundary, which is the part SwiftUI snapshot tests can't pin down.
final class PortPillFlowTests: XCTestCase {

    private let engine = PortPillFlowEngine(spacing: 4)

    private func size(_ w: CGFloat, _ h: CGFloat = 20) -> CGSize { CGSize(width: w, height: h) }

    func testKeepsEverythingOnOneRowWhenItFits() {
        let rows = engine.rows(for: [size(40), size(40)], maxWidth: 100)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.indices, [0, 1])
        XCTAssertEqual(rows.first?.width, 84, "two 40-wide pills + 4 spacing")
        XCTAssertEqual(rows.first?.height, 20, "row height is the tallest pill")
    }

    func testWrapsToNewRowWhenNextPillOverflows() {
        let rows = engine.rows(for: [size(60), size(60)], maxWidth: 100)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.indices), [[0], [1]])
    }

    /// Exact fit (`width == maxWidth`) must NOT wrap — the boundary is `>`, not
    /// `>=`. This is the classic off-by-one a fixed snapshot would never catch.
    func testExactFitStaysOnOneRow() {
        // 48 + 4 (spacing) + 48 == 100 == maxWidth
        let rows = engine.rows(for: [size(48), size(48)], maxWidth: 100)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.indices, [0, 1])
        XCTAssertEqual(rows.first?.width, 100)
    }

    func testOnePixelOverExactFitWraps() {
        // 48 + 4 + 49 == 101 > 100
        let rows = engine.rows(for: [size(48), size(49)], maxWidth: 100)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.indices), [[0], [1]])
    }

    /// A single pill wider than the whole container must still be placed on its
    /// own row, never silently dropped — the `!current.indices.isEmpty` guard.
    func testOversizedSinglePillStillGetsItsOwnRow() {
        let rows = engine.rows(for: [size(200)], maxWidth: 100)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.indices, [0])
        XCTAssertEqual(rows.first?.width, 200, "width is reported honestly, even when it overflows")
    }

    func testWrapsThreePillsIntoTwoRowsWithSpacingAccounted() {
        let rows = engine.rows(for: [size(40), size(40), size(40)], maxWidth: 100)

        // row 0: 40 + 4 + 40 = 84 fits; adding 40 → 128 > 100 → row 1.
        XCTAssertEqual(rows.map(\.indices), [[0, 1], [2]])
        XCTAssertEqual(rows[0].width, 84)
        XCTAssertEqual(rows[1].width, 40)
    }

    func testRowHeightTracksTallestPillInThatRow() {
        let rows = engine.rows(for: [size(40, 18), size(40, 26)], maxWidth: 100)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.height, 26)
    }

    func testNoPillsProducesNoRows() {
        XCTAssertTrue(engine.rows(for: [], maxWidth: 100).isEmpty)
    }
}
