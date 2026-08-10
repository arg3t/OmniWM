// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

struct MonitorStackSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?

    var nmaster: Int?
    var mfact: Double?
    var resizeStep: Double?
    var innerGap: Double?
    var useGlobalGaps: Bool?
    var stackOrientation: String?
    var singleWindowFit: String?

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        nmaster: Int? = nil,
        mfact: Double? = nil,
        resizeStep: Double? = nil,
        innerGap: Double? = nil,
        useGlobalGaps: Bool? = nil,
        stackOrientation: String? = nil,
        singleWindowFit: String? = nil
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.nmaster = nmaster
        self.mfact = mfact
        self.resizeStep = resizeStep
        self.innerGap = innerGap
        self.useGlobalGaps = useGlobalGaps
        self.stackOrientation = stackOrientation
        self.singleWindowFit = singleWindowFit
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId
        case nmaster, mfact, resizeStep, innerGap
        case useGlobalGaps, stackOrientation, singleWindowFit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        nmaster = try container.decodeIfPresent(Int.self, forKey: .nmaster)
        mfact = try container.decodeIfPresent(Double.self, forKey: .mfact)
        resizeStep = try container.decodeIfPresent(Double.self, forKey: .resizeStep)
        innerGap = try container.decodeIfPresent(Double.self, forKey: .innerGap)
        useGlobalGaps = try container.decodeIfPresent(Bool.self, forKey: .useGlobalGaps)
        stackOrientation = try container.decodeIfPresent(String.self, forKey: .stackOrientation)
        singleWindowFit = try container.decodeIfPresent(String.self, forKey: .singleWindowFit)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try DisplayUUID.encode(
            monitorDisplayUUID,
            displayId: monitorDisplayId,
            to: &container,
            uuidKey: .monitorDisplayUUID,
            displayIdKey: .monitorDisplayId
        )
        try container.encodeIfPresent(nmaster, forKey: .nmaster)
        try container.encodeIfPresent(mfact, forKey: .mfact)
        try container.encodeIfPresent(resizeStep, forKey: .resizeStep)
        try container.encodeIfPresent(innerGap, forKey: .innerGap)
        try container.encodeIfPresent(useGlobalGaps, forKey: .useGlobalGaps)
        try container.encodeIfPresent(stackOrientation, forKey: .stackOrientation)
        try container.encodeIfPresent(singleWindowFit, forKey: .singleWindowFit)
    }
}

struct ResolvedStackSettings: Equatable {
    let nmaster: Int
    let mfact: CGFloat
    let resizeStep: CGFloat
    let innerGap: CGFloat
    let stackOrientation: StackOrientation
    let singleWindowFit: SingleWindowFit
    let useGlobalGaps: Bool
}
