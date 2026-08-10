// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct MonitorSetupProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var monitorSignature: String
    var defaultLayoutType: LayoutType?
    var gapSize: Double?
    var workspaceConfigurations: [WorkspaceConfiguration]?

    init(
        id: UUID = UUID(),
        name: String,
        monitorSignature: String,
        defaultLayoutType: LayoutType? = nil,
        gapSize: Double? = nil,
        workspaceConfigurations: [WorkspaceConfiguration]? = nil
    ) {
        self.id = id
        self.name = name
        self.monitorSignature = monitorSignature
        self.defaultLayoutType = defaultLayoutType
        self.gapSize = gapSize
        self.workspaceConfigurations = workspaceConfigurations
    }

    static func computeSignature(from monitors: [Monitor]) -> String {
        monitors.compactMap(\.displayUUID).sorted().joined(separator: ",")
    }
}
