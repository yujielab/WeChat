import XCTest
@testable import CuvenCore

final class DuoLayoutMetricsTests: XCTestCase {

    func testStandardIPhoneCompactPortraitMetrics() {
        let m = DuoLayoutMetrics.compute(
            size: CGSize(width: 393, height: 852),
            safeTop: 59,
            safeBottom: 34,
            safeLeft: 0,
            safeRight: 0,
            activePairStartsAtThread: false,
            postureOverride: nil
        )
        XCTAssertEqual(m.posture, .iPhoneCompact)
        XCTAssertFalse(m.hasRightSystemColumn)
        XCTAssertEqual(m.visibleColumnCount, 1)
        XCTAssertEqual(m.leadingColumnWidth, 393)
        XCTAssertEqual(m.trailingColumnWidth, 0)
        XCTAssertEqual(m.threadContentWidth, 393)
        XCTAssertNil(m.hingeDivisionRect)
        XCTAssertEqual(m.railWidth, 0)
        XCTAssertEqual(m.railTopReserve, 0)
    }

    func testSymmetricIPhone18ProMaxLandscapeNeverTriggersDuoRightRail() {
        // iPhone 18 Pro Max landscape: ~956×440 with symmetric ~62pt Dynamic Island / home insets
        let m62 = DuoLayoutMetrics.compute(
            size: CGSize(width: 956, height: 440),
            safeTop: 0,
            safeBottom: 21,
            safeLeft: 62,
            safeRight: 62,
            activePairStartsAtThread: false,
            postureOverride: nil
        )
        XCTAssertEqual(m62.posture, .iPhoneSplit)
        XCTAssertFalse(m62.hasRightSystemColumn, "Symmetric 62pt L/R safe areas must NOT trigger Duo right rail")
        XCTAssertEqual(m62.visibleColumnCount, 2)
        XCTAssertEqual(m62.leadingColumnWidth, 344) // round(956 * 0.36) = 344
        XCTAssertEqual(m62.trailingColumnWidth, 612)
        XCTAssertEqual(m62.railWidth, 0)

        // Even if symmetric safe areas exceed 64pt (e.g. 68pt L & 68pt R), asymmetry check blocks Duo rail
        let m68Symmetric = DuoLayoutMetrics.compute(
            size: CGSize(width: 956, height: 440),
            safeTop: 0,
            safeBottom: 21,
            safeLeft: 68,
            safeRight: 68,
            activePairStartsAtThread: false,
            postureOverride: nil
        )
        XCTAssertEqual(m68Symmetric.posture, .iPhoneSplit)
        XCTAssertFalse(m68Symmetric.hasRightSystemColumn)
    }

    func testIPhoneDuoClosedPortraitAndLandscapeReserves() {
        // Closed portrait: 466×678, safeRight = 91 -> 170pt camera + clock + silent ring reserve
        let portrait = DuoLayoutMetrics.compute(
            size: CGSize(width: 466, height: 678),
            safeTop: 20,
            safeBottom: 24,
            safeLeft: 0,
            safeRight: 91,
            activePairStartsAtThread: false,
            postureOverride: nil
        )
        XCTAssertEqual(portrait.posture, .duoClosed)
        XCTAssertTrue(portrait.hasRightSystemColumn)
        XCTAssertEqual(portrait.visibleColumnCount, 1)
        XCTAssertEqual(portrait.leadingColumnWidth, 466)
        XCTAssertEqual(portrait.trailingColumnWidth, 0)
        XCTAssertEqual(portrait.threadContentWidth, 375) // 466 - 91
        XCTAssertEqual(portrait.railWidth, 52)
        XCTAssertEqual(portrait.railCenterFromRight, 49)
        XCTAssertEqual(portrait.railTopReserve, 170)

        // Closed outer landscape: 678×466 (width < 700, shortSide = 466 < 560) -> 12pt top reserve
        let landscape = DuoLayoutMetrics.compute(
            size: CGSize(width: 678, height: 466),
            safeTop: 0,
            safeBottom: 21,
            safeLeft: 0,
            safeRight: 91,
            activePairStartsAtThread: false,
            postureOverride: nil
        )
        XCTAssertEqual(landscape.posture, .duoClosed)
        XCTAssertTrue(landscape.hasRightSystemColumn)
        XCTAssertEqual(landscape.railTopReserve, 12)
    }

    func testIPhoneDuoOpenConstant525ptZeroReflowThreadWidth() {
        // Unfolded inner display: 951×669, safeRight = 84
        // Pair 1: List | Thread -> 342 | 609 (525 content + 84 rail)
        let listAndThread = DuoLayoutMetrics.compute(
            size: CGSize(width: 951, height: 669),
            safeTop: 16,
            safeBottom: 20,
            safeLeft: 0,
            safeRight: 84,
            activePairStartsAtThread: false,
            postureOverride: nil
        )
        XCTAssertEqual(listAndThread.posture, .duoOpen)
        XCTAssertTrue(listAndThread.hasRightSystemColumn)
        XCTAssertEqual(listAndThread.visibleColumnCount, 2)
        XCTAssertEqual(listAndThread.leadingColumnWidth, 342)
        XCTAssertEqual(listAndThread.trailingColumnWidth, 609)
        XCTAssertEqual(listAndThread.threadContentWidth, 525)
        XCTAssertEqual(listAndThread.railWidth, 52)
        XCTAssertEqual(listAndThread.railCenterFromRight, 49)
        XCTAssertEqual(listAndThread.railTopReserve, 118)

        // Pair 2: Thread | Artifact -> 525 | 426 (342 details + 84 rail)
        let threadAndArtifact = DuoLayoutMetrics.compute(
            size: CGSize(width: 951, height: 669),
            safeTop: 16,
            safeBottom: 20,
            safeLeft: 0,
            safeRight: 84,
            activePairStartsAtThread: true,
            postureOverride: nil
        )
        XCTAssertEqual(threadAndArtifact.posture, .duoOpen)
        XCTAssertEqual(threadAndArtifact.leadingColumnWidth, 525)
        XCTAssertEqual(threadAndArtifact.trailingColumnWidth, 426)
        XCTAssertEqual(threadAndArtifact.threadContentWidth, 525)
        XCTAssertEqual(
            listAndThread.threadContentWidth,
            threadAndArtifact.threadContentWidth,
            "Thread content width must remain identically 525pt across List|Thread and Thread|Artifact"
        )
    }

    func testDuoHalfBookAndHalfLaptopCreaseDivisionGeometry() {
        let book = DuoLayoutMetrics.compute(
            size: CGSize(width: 951, height: 669),
            safeTop: 16,
            safeBottom: 20,
            safeLeft: 0,
            safeRight: 84,
            activePairStartsAtThread: false,
            postureOverride: .duoHalfBook
        )
        XCTAssertEqual(book.posture, .duoHalfBook)
        XCTAssertTrue(book.hasRightSystemColumn)
        XCTAssertEqual(book.visibleColumnCount, 2)
        XCTAssertEqual(book.leadingColumnWidth, 462)
        XCTAssertEqual(book.trailingColumnWidth, 461)
        XCTAssertEqual(book.hingeDivisionRect, CGRect(x: 462, y: 0, width: 28, height: 669))

        let laptop = DuoLayoutMetrics.compute(
            size: CGSize(width: 669, height: 951),
            safeTop: 20,
            safeBottom: 20,
            safeLeft: 0,
            safeRight: 0,
            activePairStartsAtThread: false,
            postureOverride: .duoHalfLaptop
        )
        XCTAssertEqual(laptop.posture, .duoHalfLaptop)
        XCTAssertFalse(laptop.hasRightSystemColumn)
        XCTAssertEqual(laptop.visibleColumnCount, 1)
        XCTAssertNotNil(laptop.hingeDivisionRect)
        XCTAssertEqual(laptop.hingeDivisionRect?.width, 669)
        XCTAssertEqual(laptop.hingeDivisionRect?.height, 28)
    }

    func testDuoColumnMathStripWindowAndOffsets() {
        let duoOpen = DuoLayoutMetrics.compute(
            size: CGSize(width: 951, height: 669),
            safeTop: 16,
            safeBottom: 20,
            safeLeft: 0,
            safeRight: 84,
            activePairStartsAtThread: false,
            postureOverride: nil
        )
        XCTAssertEqual(DuoColumnMath.windowStart(focusedColumn: 0, visibleColumnCount: 2), 0)
        XCTAssertEqual(DuoColumnMath.windowStart(focusedColumn: 1, visibleColumnCount: 2), 1)
        XCTAssertEqual(DuoColumnMath.windowStart(focusedColumn: 2, visibleColumnCount: 2), 1)
        XCTAssertEqual(DuoColumnMath.windowStart(focusedColumn: 3, visibleColumnCount: 2), 2)

        let widthsAt1 = DuoColumnMath.columnWidths(metrics: duoOpen, windowStart: 1)
        XCTAssertEqual(widthsAt1, [342, 342, 609, 426])
        XCTAssertEqual(DuoColumnMath.stripOffsetX(columnWidths: widthsAt1, windowStart: 1), -342)

        let widthsAt2 = DuoColumnMath.columnWidths(metrics: duoOpen, windowStart: 2)
        XCTAssertEqual(widthsAt2, [342, 342, 525, 426])
        XCTAssertEqual(DuoColumnMath.stripOffsetX(columnWidths: widthsAt2, windowStart: 2), -684)
        XCTAssertEqual(DuoColumnMath.railRightOffset(for: duoOpen), 23)
    }

    func testSpringSolverAndVelocityProjectorPhysics() {
        // Boundary conditions
        XCTAssertEqual(SpringSolver.state(at: 0, from: 100, to: 400, damping: 1.0, response: 0.34), 100, accuracy: 0.001)
        XCTAssertEqual(SpringSolver.state(at: 5.0, from: 100, to: 400, damping: 1.0, response: 0.34), 400, accuracy: 0.001)

        // Critically damped spring never overshoots target
        for step in 1...60 {
            let t = Double(step) * 0.015
            let pos = SpringSolver.state(at: t, from: 0, to: 100, velocity: 0, damping: 1.0, response: 0.34)
            XCTAssertLessThanOrEqual(pos, 100.0001)
            XCTAssertGreaterThanOrEqual(pos, 0.0)
        }

        // Underdamped bubblePop spring (damping = 0.76) overshoots > 100 before settling to 100
        var maxPos = 0.0
        for step in 1...80 {
            let pos = SpringSolver.state(at: Double(step) * 0.01, from: 0, to: 100, velocity: 0, damping: 0.76, response: 0.36)
            maxPos = max(maxPos, pos)
        }
        XCTAssertGreaterThan(maxPos, 101.0)

        // Initial velocity matches analytical derivative at t = 0
        let v0 = SpringSolver.velocity(at: 0, from: 0, to: 100, initialVelocity: 250, damping: 0.88, response: 0.52)
        XCTAssertEqual(v0, 250, accuracy: 1.5)

        // VelocityProjector: ((1000 / 1000) * 0.998) / (1 - 0.998) = 0.998 / 0.002 = 499
        let projected = SpringSolver.VelocityProjector.project(velocity: 1000, decelerationRate: 0.998)
        XCTAssertEqual(Double(projected), 499.0, accuracy: 0.01)

        // Rubberband antisymmetry and progressive sub-linear resistance
        let posRB = SpringSolver.rubberband(overshoot: 120, dimension: 400, resistance: 0.55)
        let negRB = SpringSolver.rubberband(overshoot: -120, dimension: 400, resistance: 0.55)
        XCTAssertEqual(Double(posRB), Double(-negRB), accuracy: 0.0001)
        XCTAssertLessThan(posRB, 120)
        XCTAssertGreaterThan(posRB, 0)
    }
}
