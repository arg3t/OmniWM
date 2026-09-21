// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO

@MainActor
final class OverviewWallpaperCache {
    private struct Key: Hashable {
        let url: URL
        let maxPixelSize: Int
    }

    private var images: [Key: CGImage] = [:]
    private var urlsByDisplay: [CGDirectDisplayID: URL] = [:]
    var desktopImageURL: (CGDirectDisplayID) -> URL? = { displayId in
        NSScreen.screens.first { $0.displayId == displayId }
            .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    static func bucketedPixelSize(_ pixelSize: CGFloat) -> Int {
        let sizes = [64, 512, 1024, 2048, 4096]
        return sizes.first { CGFloat($0) >= pixelSize } ?? 4096
    }

    func image(for displayId: CGDirectDisplayID, maxPixelSize: Int) -> CGImage? {
        let url = desktopImageURL(displayId)
        let previousURL = urlsByDisplay[displayId]
        urlsByDisplay[displayId] = url
        if let previousURL, previousURL != url, !urlsByDisplay.values.contains(previousURL) {
            images = images.filter { $0.key.url != previousURL }
        }
        guard let url else { return nil }
        let key = Key(url: url, maxPixelSize: maxPixelSize)
        if let cached = images[key] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        images[key] = image
        return image
    }

    func clear() {
        images.removeAll()
        urlsByDisplay.removeAll()
    }
}
