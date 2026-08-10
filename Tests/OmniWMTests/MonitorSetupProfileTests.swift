// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class MonitorSetupProfileTests: XCTestCase {
    private let displayUUIDA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let displayUUIDB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let displayUUIDC = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"

    // MARK: - computeSignature

    func testComputeSignatureWithEmptyMonitorsReturnsEmptyString() {
        XCTAssertEqual(MonitorSetupProfile.computeSignature(from: []), "")
    }

    func testComputeSignatureIsOrderIndependent() {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)

        let forward = MonitorSetupProfile.computeSignature(from: [first, second])
        let reversed = MonitorSetupProfile.computeSignature(from: [second, first])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, [displayUUIDA, displayUUIDB].sorted().joined(separator: ","))
    }

    func testComputeSignatureExcludesMonitorsWithNilDisplayUUID() {
        let withUUID = makeMonitor(displayId: 2, name: "Stable", displayUUID: displayUUIDA)
        let withoutUUID = makeMonitor(displayId: 3, name: "Fallback", displayUUID: nil)

        let signature = MonitorSetupProfile.computeSignature(from: [withUUID, withoutUUID])

        XCTAssertEqual(signature, displayUUIDA)
    }

    // MARK: - activeSetupProfile(for:)

    @MainActor
    func testActiveSetupProfileReturnsMatchingProfile() {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)
        let signature = MonitorSetupProfile.computeSignature(from: [first, second])
        let profile = MonitorSetupProfile(
            name: "Home",
            monitorSignature: signature,
            defaultLayoutType: .dwindle,
            gapSize: 12
        )
        let settings = makeSettingsStore()
        settings.monitorSetupProfiles = [profile]

        let active = settings.activeSetupProfile(for: [second, first])

        XCTAssertEqual(active, profile)
    }

    @MainActor
    func testActiveSetupProfileReturnsNilWhenNoMatch() {
        let first = makeMonitor(displayId: 2, name: "First", displayUUID: displayUUIDA)
        let second = makeMonitor(displayId: 3, name: "Second", displayUUID: displayUUIDB)
        let other = makeMonitor(displayId: 4, name: "Other", displayUUID: displayUUIDC)
        let profile = MonitorSetupProfile(
            name: "Home",
            monitorSignature: MonitorSetupProfile.computeSignature(from: [first, second])
        )
        let settings = makeSettingsStore()
        settings.monitorSetupProfiles = [profile]

        XCTAssertNil(settings.activeSetupProfile(for: [first]))
        XCTAssertNil(settings.activeSetupProfile(for: [first, other]))
        XCTAssertNil(settings.activeSetupProfile(for: [first, second, other]))
    }

    @MainActor
    func testActiveSetupProfileReturnsNilWhenSignatureIsEmpty() {
        let monitor = makeMonitor(displayId: 2, name: "Fallback", displayUUID: nil)
        let settings = makeSettingsStore()
        settings.monitorSetupProfiles = [
            MonitorSetupProfile(name: "Empty", monitorSignature: "")
        ]

        XCTAssertNil(settings.activeSetupProfile(for: []))
        XCTAssertNil(settings.activeSetupProfile(for: [monitor]))
    }

    // MARK: - Helpers

    private func makeMonitor(
        displayId: CGDirectDisplayID,
        name: String,
        displayUUID: String?
    ) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: CGFloat(displayId) * 100, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: CGFloat(displayId) * 100, y: 0, width: 1440, height: 900),
            hasNotch: false,
            name: name,
            displayUUID: displayUUID
        )
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMMonitorSetupProfileTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return SettingsStore(
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
    }
}
