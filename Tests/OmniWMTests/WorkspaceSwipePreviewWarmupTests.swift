// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwipePreviewWarmupTests: XCTestCase {
    func testWarmupStopsEachStreamAtFirstFrameAndCompletesWithoutPanel() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = makePreview(capture)
        let first = item(1)
        let second = item(2)
        preview.warm(source: [first], destination: [second], monitor: monitor)
        await driver.waitForStarts(2)
        driver.completeAllStarts()
        XCTAssertTrue(preview.isWarming)
        XCTAssertTrue(capture.hasPendingFirstFrames)

        await publish(try makeOverviewPreviewFrame(), through: driver.streams[0], into: capture)
        await driver.waitForStops(1)
        XCTAssertTrue(preview.isWarming)
        XCTAssertTrue(capture.hasPendingFirstFrames)
        XCTAssertEqual(driver.streams[0].stopCount, 1)
        XCTAssertEqual(driver.streams[1].stopCount, 0)
        await publish(try makeOverviewPreviewFrame(), through: driver.streams[1], into: capture)
        await driver.waitForStops(2)

        XCTAssertFalse(preview.isWarming)
        XCTAssertFalse(capture.hasPendingFirstFrames)
        XCTAssertFalse(preview.isVisible)
        XCTAssertNotNil(capture.preview(for: first.handle))
        XCTAssertNotNil(capture.preview(for: second.handle))
        driver.streams[0].output.offer(try makeOverviewPreviewFrame())
        XCTAssertNil(driver.streams[0].output.take())
        XCTAssertEqual(driver.streams.count, 2)
    }

    func testWarmupCompletesWhenOneRequestFailsAndOtherPublishes() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = makePreview(capture)
        let first = item(1)
        let second = item(2)
        preview.warm(source: [first], destination: [second], monitor: monitor)
        await driver.waitForStarts(2)
        driver.streams[0].completeStart(error: NSError(domain: "Warmup test", code: 1))
        driver.streams[1].completeStart()
        await driver.waitForStops(1)
        XCTAssertTrue(preview.isWarming)

        await publish(try makeOverviewPreviewFrame(), through: driver.streams[1], into: capture)
        await driver.waitForStops(2)

        XCTAssertFalse(preview.isWarming)
        XCTAssertFalse(capture.hasPendingFirstFrames)
        XCTAssertNil(capture.preview(for: first.handle))
        XCTAssertNotNil(capture.preview(for: second.handle))
        XCTAssertFalse(preview.isVisible)
    }

    func testPhysicalPreparationConvertsWarmupToContinuousCapture() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = makePreview(capture)
        let item = item(1)
        preview.warm(source: [item], destination: [], monitor: monitor)
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        preview.prepare(source: [item], destination: [], monitor: monitor)
        XCTAssertFalse(preview.isWarming)

        await publish(try makeOverviewPreviewFrame(), through: driver.streams[0], into: capture)
        XCTAssertEqual(driver.streams[0].stopCount, 0)
        let second = try makeOverviewPreviewFrame()
        await publish(second, through: driver.streams[0], into: capture)
        XCTAssertTrue(capture.preview(for: item.handle) === second)
        XCTAssertEqual(driver.streams.count, 1)
        preview.stop()
        await driver.waitForStops(1)
    }

    func testCandidateChangesRetainImagesAndRekeyInvalidatesUnrepresentedCache() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = makePreview(capture)
        let first = item(1)
        let second = item(2)
        let firstFrame = try makeOverviewPreviewFrame()
        preview.warm(source: [first], destination: [], monitor: monitor)
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        await publish(firstFrame, through: driver.streams[0], into: capture)
        await driver.waitForStops(1)

        preview.warm(source: [second], destination: [], monitor: monitor)
        await driver.waitForStarts(2)
        XCTAssertTrue(capture.preview(for: first.handle) === firstFrame)
        driver.completeAllStarts()
        await publish(try makeOverviewPreviewFrame(), through: driver.streams[1], into: capture)
        await driver.waitForStops(2)
        XCTAssertTrue(capture.preview(for: first.handle) === firstFrame)

        first.handle.id = WindowToken(pid: 123, windowId: 3)
        XCTAssertNil(capture.preview(for: first.handle))
        preview.prepare(source: [first], destination: [], monitor: monitor)
        await driver.waitForStarts(3)
        XCTAssertNil(capture.preview(for: first.handle))
        XCTAssertNotNil(capture.preview(for: second.handle))
        driver.completeAllStarts()
        preview.stop()
        await driver.waitForStops(3)
    }

    func testLateRetiredSourceCannotCompleteReplacementWarmup() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = makePreview(capture)
        let original = item(1)
        let replacement = item(1)
        preview.warm(source: [original], destination: [], monitor: monitor)
        await driver.waitForStarts(1)
        preview.warm(source: [replacement], destination: [], monitor: monitor)
        await driver.waitForStarts(2)
        driver.completeAllStarts()
        await driver.waitForStops(1)
        driver.streams[0].output.offer(try makeOverviewPreviewFrame())
        XCTAssertNil(driver.streams[0].output.take())
        XCTAssertTrue(preview.isWarming)
        XCTAssertNil(capture.preview(for: replacement.handle))

        await publish(try makeOverviewPreviewFrame(), through: driver.streams[1], into: capture)
        await driver.waitForStops(2)
        XCTAssertFalse(preview.isWarming)
        XCTAssertNotNil(capture.preview(for: replacement.handle))
        XCTAssertNil(capture.preview(for: original.handle))
    }

    func testRetainedCandidateImagesStillRespectBudgetAfterWarmup() async throws {
        let frame = try makeOverviewPreviewFrame()
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(maximumRetainedBytes: frame.surface.allocationSize)
        let preview = makePreview(capture)
        let first = item(1)
        let second = item(2)
        preview.warm(source: [first], destination: [], monitor: monitor)
        await driver.waitForStarts(1)
        driver.completeAllStarts()
        await publish(frame, through: driver.streams[0], into: capture)
        await driver.waitForStops(1)
        preview.warm(source: [second], destination: [], monitor: monitor)
        await driver.waitForStarts(2)
        driver.completeAllStarts()
        let recent = try makeOverviewPreviewFrame()
        await publish(recent, through: driver.streams[1], into: capture)
        await driver.waitForStops(2)

        XCTAssertFalse(preview.isWarming)
        XCTAssertEqual(capture.cachedByteCount, recent.surface.allocationSize)
        XCTAssertTrue(capture.preview(for: second.handle) === recent)
        XCTAssertNil(capture.preview(for: first.handle))
        capture.releaseCache()
        XCTAssertEqual(capture.cachedByteCount, 0)
    }

    func testSevenRetinaCandidatesRemainCachedAfterWarmup() async throws {
        let budget = 128 * 1_024 * 1_024
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(maximumRetainedBytes: budget)
        let items = (0 ..< 7).map { index in
            WorkspaceSwipePreview.Item(
                handle: WindowHandle(id: WindowToken(pid: 123, windowId: 100 + index)),
                frame: CGRect(
                    x: 0, y: 0,
                    width: index == 6 ? 2554 : 1259,
                    height: index == 6 ? 1404 : 1380
                )
            )
        }
        let requests = items.map { $0.captureRequest(backingScale: 2) }
        capture.reconcile(
            represented: Set(items.map(\.handle)),
            visible: requests,
            retainingUnrepresentedPreviews: true,
            firstFrameOnly: true
        )
        await driver.waitForStarts(4)
        XCTAssertEqual(driver.streams.count, 4)
        driver.completeAllStarts()
        await driver.waitForStarts(7)
        driver.completeAllStarts()
        for stream in driver.streams {
            let frame = try makeOverviewPreviewFrame(
                width: stream.request.pixelWidth,
                height: stream.request.pixelHeight
            )
            await publish(frame, through: stream, into: capture)
        }
        await driver.waitForStops(7)
        XCTAssertFalse(capture.hasPendingFirstFrames)
        for item in items {
            XCTAssertNotNil(
                capture.preview(for: item.handle),
                "Every requested candidate must publish before retirement"
            )
        }

        capture.clear()

        XCTAssertLessThanOrEqual(capture.cachedByteCount, budget)
        for item in items {
            XCTAssertNotNil(
                capture.preview(for: item.handle),
                "Warmup evicted current candidate \(item.handle.token.windowId) before the gesture could use it"
            )
        }
        XCTAssertTrue(driver.streams.allSatisfy { $0.stopCount == 1 })
    }

    private func makePreview(_ capture: OverviewThumbnailCapture) -> WorkspaceSwipePreview {
        WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(), previewCapture: capture, hasCaptureAccess: { true }
        )
    }

    private var monitor: Monitor {
        Monitor(
            id: .init(displayId: 999), displayId: 999,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 30, width: 1200, height: 750),
            hasNotch: false, name: "Preview warmup test"
        )
    }

    private func item(_ id: Int) -> WorkspaceSwipePreview.Item {
        .init(
            handle: WindowHandle(id: WindowToken(pid: 123, windowId: id)),
            frame: CGRect(x: 50, y: 50, width: 400, height: 300)
        )
    }

    private func publish(
        _ frame: OverviewPreviewFrame,
        through stream: OverviewPreviewTestStream,
        into capture: OverviewThumbnailCapture
    ) async {
        let published = expectation(description: "warmup frame published")
        capture.onPreview = { _, preview in if preview === frame { published.fulfill() } }
        stream.output.offer(frame)
        await fulfillment(of: [published], timeout: 1)
    }
}
