// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct MouseContainment {
    let layout: [MonitorRoutingSettings]
    let monitors: [Monitor]

    enum Verdict: Equatable {
        case allow
        case wall(clamped: CGPoint)
    }

    func evaluate(
        location: CGPoint,
        source: Monitor,
        destination: Monitor,
        margin: CGFloat
    ) -> Verdict {
        guard source.id != destination.id else { return .allow }
        guard MonitorRouting.completeLayout(layout, for: monitors) != nil else { return .allow }
        guard let direction = Self.physicalDirection(from: source, to: destination) else { return .allow }

        switch MonitorRouting.cursorRoute(
            from: source,
            direction: direction,
            edgeRatio: Self.edgeRatio(at: location, from: source, direction: direction),
            layout: layout,
            monitors: monitors
        ) {
        case let .route(route) where route.monitor.id == destination.id:
            return .allow
        case .fallBackToMacOS:
            return .allow
        case .route,
             .edge:
            break
        }

        guard isReachable(from: source, to: destination) else {
            return .allow
        }

        return .wall(clamped: Self.clamped(location, inside: source.frame, margin: margin))
    }

    private static func physicalDirection(from source: Monitor, to destination: Monitor) -> Direction? {
        let dx = destination.frame.center.x - source.frame.center.x
        let dy = destination.frame.center.y - source.frame.center.y
        let absX = abs(dx)
        let absY = abs(dy)

        guard absX != absY else { return nil }
        if absX > absY {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .up : .down
    }

    private static func edgeRatio(at location: CGPoint, from source: Monitor, direction: Direction) -> CGFloat {
        let ratio: CGFloat
        switch direction {
        case .left,
             .right:
            guard source.frame.height > 0 else { return 0.5 }
            ratio = (source.frame.maxY - location.y) / source.frame.height
        case .up,
             .down:
            guard source.frame.width > 0 else { return 0.5 }
            ratio = (location.x - source.frame.minX) / source.frame.width
        }
        return min(max(ratio, 0), 1)
    }

    private func isReachable(
        from source: Monitor,
        to destination: Monitor
    ) -> Bool {
        let directions: [Direction] = [.left, .right, .up, .down]
        var visited = Set<Monitor.ID>()
        var pending = [source]
        visited.insert(source.id)

        while let current = pending.first {
            pending.removeFirst()
            if current.id == destination.id {
                return true
            }
            for direction in directions {
                guard let neighbors = MonitorRouting.cursorNeighbors(
                    from: current,
                    direction: direction,
                    layout: layout,
                    monitors: monitors
                ) else {
                    return false
                }
                for neighbor in neighbors where visited.insert(neighbor.id).inserted {
                    pending.append(neighbor)
                }
            }
        }

        return false
    }

    private static func clamped(_ point: CGPoint, inside frame: CGRect, margin: CGFloat) -> CGPoint {
        let inset = margin + 1
        return CGPoint(
            x: MouseWarpGeometry.clampedCoordinate(
                point.x,
                min: frame.minX,
                max: frame.maxX,
                inset: inset
            ),
            y: MouseWarpGeometry.clampedCoordinate(
                point.y,
                min: frame.minY,
                max: frame.maxY,
                inset: inset
            )
        )
    }
}
