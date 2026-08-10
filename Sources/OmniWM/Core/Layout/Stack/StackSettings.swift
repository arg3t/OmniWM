// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

enum StackOrientation: String, Codable {
    case horizontal
    case vertical
}

struct StackSettings {
    var nmaster: Int = 1
    var mfact: CGFloat = 0.55
    var resizeStep: CGFloat = 0.05
    var innerGap: CGFloat = 8.0

    var stackOrientation: StackOrientation = .vertical
    var singleWindowFit: SingleWindowFit = .fullScreen

    func clampedMfact(_ mfact: CGFloat) -> CGFloat {
        min(max(mfact, 0.1), 0.9)
    }
}
