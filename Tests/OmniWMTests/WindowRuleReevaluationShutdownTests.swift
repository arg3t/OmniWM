// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowRuleReevaluationShutdownTests: XCTestCase {
    func testResetCancelsReevaluationAlreadyAwaitingNativeFacts() async {
        let controller = WindowAdmissionTestSupport.controller(prefix: "RuleShutdown")
        defer { controller.serviceLifecycleManager.stop() }
        let started = expectation(description: "Rule evaluation waiting for native facts")
        let finished = expectation(description: "Cancelled evaluation observes reset")
        var release: CheckedContinuation<Void, Never>?
        var cancelled = false
        let scheduler = WindowRuleReevaluationScheduler(controller: controller) { _, _ in
            await withCheckedContinuation { release = $0
                started.fulfill()
            }
            cancelled = Task.isCancelled
            finished.fulfill()
            return WindowRuleReevaluationOutcome(
                resolvedAnyTarget: false,
                evaluatedAnyWindow: false,
                relayoutNeeded: false,
                stale: true
            )
        }
        scheduler.schedule(targets: [.pid(696_301)])
        await fulfillment(of: [started], timeout: 2)
        scheduler.reset()
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(cancelled)
        scheduler.reset()
    }
}
