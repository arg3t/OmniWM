// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class StackLayoutEngineTests: XCTestCase {
    private let workspaceId = WorkspaceDescriptor.ID()
    private let screen = CGRect(x: 10, y: 20, width: 1_000, height: 900)

    func testLayoutUsesOneMasterAndAnEqualStack() {
        let engine = StackLayoutEngine()
        let tokens = [token(1), token(2), token(3)]
        engine.isMutationSanctioned = true
        engine.syncWindows(tokens, in: workspaceId)

        let frames = engine.calculateLayout(
            for: workspaceId,
            screen: screen,
            fullscreenScreen: screen,
            innerGap: 10,
            excludedTokens: []
        )

        XCTAssertEqual(frames[tokens[0]], CGRect(x: 10, y: 20, width: 544.5, height: 900))
        XCTAssertEqual(frames[tokens[1]], CGRect(x: 564.5, y: 20, width: 445.5, height: 445))
        XCTAssertEqual(frames[tokens[2]], CGRect(x: 564.5, y: 475, width: 445.5, height: 445))
    }

    func testNewWindowJoinsBottomOfStack() {
        let engine = StackLayoutEngine()
        let first = token(1)
        let second = token(2)
        let newest = token(3)
        engine.isMutationSanctioned = true
        engine.syncWindows([first, second], in: workspaceId)
        engine.syncWindows([first, second, newest], in: workspaceId)

        XCTAssertEqual(engine.orderedTokens(in: workspaceId), [first, second, newest])
    }

    func testExcludedMasterDoesNotKeepLayoutSpace() {
        let engine = StackLayoutEngine()
        let master = token(1)
        let visible = token(2)
        engine.isMutationSanctioned = true
        engine.syncWindows([master, visible], in: workspaceId)

        let frames = engine.calculateLayout(
            for: workspaceId,
            screen: screen,
            fullscreenScreen: screen,
            innerGap: 10,
            excludedTokens: [master]
        )

        XCTAssertEqual(frames, [visible: screen])
        XCTAssertEqual(engine.orderedTokens(in: workspaceId), [master, visible])
    }

    func testFullscreenKeepsSiblingFramesCurrent() {
        let engine = StackLayoutEngine()
        let tokens = [token(1), token(2), token(3)]
        let fullscreenScreen = CGRect(x: 0, y: 0, width: 1_200, height: 1_000)
        engine.isMutationSanctioned = true
        engine.syncWindows(Array(tokens.prefix(2)), in: workspaceId)
        XCTAssertTrue(engine.toggleFullscreen(tokens[0], in: workspaceId))
        engine.syncWindows(tokens, in: workspaceId)

        let frames = engine.calculateLayout(
            for: workspaceId,
            screen: screen,
            fullscreenScreen: fullscreenScreen,
            innerGap: 10,
            excludedTokens: []
        )

        XCTAssertEqual(frames[tokens[0]], fullscreenScreen)
        XCTAssertEqual(frames[tokens[1]], CGRect(x: 564.5, y: 20, width: 445.5, height: 445))
        XCTAssertEqual(frames[tokens[2]], CGRect(x: 564.5, y: 475, width: 445.5, height: 445))
    }

    func testFocusAndMoveWrapThroughTheWholeClientOrder() throws {
        let engine = StackLayoutEngine()
        let tokens = [token(1), token(2), token(3)]
        let eligibleTokens = Set(tokens)
        engine.isMutationSanctioned = true
        engine.syncWindows(tokens, in: workspaceId)
        XCTAssertTrue(engine.activate(tokens[1], in: workspaceId))

        XCTAssertEqual(
            engine.neighbor(of: tokens[1], direction: .up, among: eligibleTokens, in: workspaceId),
            tokens[2]
        )
        XCTAssertEqual(
            engine.neighbor(of: tokens[0], direction: .down, among: eligibleTokens, in: workspaceId),
            tokens[2]
        )
        XCTAssertTrue(engine.move(tokens[1], direction: .up, among: eligibleTokens, in: workspaceId))
        XCTAssertEqual(engine.orderedTokens(in: workspaceId), [tokens[0], tokens[2], tokens[1]])
        XCTAssertTrue(engine.move(tokens[1], direction: .up, among: eligibleTokens, in: workspaceId))
        XCTAssertEqual(engine.orderedTokens(in: workspaceId), [tokens[1], tokens[2], tokens[0]])
        XCTAssertEqual(engine.selectedToken(in: workspaceId), tokens[1])
    }

    func testDefaultFocusAndMoveBindingsFollowStackDirection() throws {
        let controller = makeController()
        controller.settings.workspaces.configurations.append(WorkspaceConfiguration(name: "80", layoutType: .stack))
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "80"))
        let monitor = try XCTUnwrap(controller.workspaceManager.monitors.first)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))

        let tokens = [token(11), token(12), token(13)]
        for token in tokens {
            controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
                pid: token.pid,
                windowId: token.windowId,
                to: workspaceId
            )
        }
        let engine = try XCTUnwrap(controller.stackEngine)
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.syncWindows(tokens, in: workspaceId)
            XCTAssertTrue(engine.activate(tokens[1], in: workspaceId))
        }
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(tokens[1], in: workspaceId, onMonitor: monitor.id))

        XCTAssertEqual(controller.commandHandler.performCommand(.focus(.up)), .executed)
        XCTAssertEqual(engine.selectedToken(in: workspaceId), tokens[2])
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            XCTAssertTrue(engine.activate(tokens[1], in: workspaceId))
        }
        XCTAssertEqual(controller.commandHandler.performCommand(.move(.up)), .executed)
        XCTAssertEqual(engine.orderedTokens(in: workspaceId), [tokens[0], tokens[2], tokens[1]])
    }

    private func token(_ windowId: Int) -> WindowToken {
        WindowToken(pid: 990_000, windowId: windowId)
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StackLayoutEngineTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }
}
