// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum MonitorRouting {
    enum Adjacency: Equatable {
        case monitor(Monitor)
        case edge
        case fallBackToMacOS
    }

    struct CursorRoute {
        let monitor: Monitor
        let destinationRatio: CGFloat
    }

    enum CursorAdjacency {
        case route(CursorRoute)
        case edge
        case fallBackToMacOS
    }

    static func arrangementIndex(for monitors: [Monitor], in arrangements: [MonitorArrangement]) -> Int? {
        guard !monitors.isEmpty else { return nil }
        var selectedIndex: Int?
        var selectedCount = Int.max

        for index in arrangements.indices {
            let layout = arrangements[index].monitors
            guard layout.count >= monitors.count,
                  layout.count < selectedCount,
                  monitors.allSatisfy({ MonitorSettingsStore.get(for: $0, in: layout) != nil })
            else { continue }
            if layout.count == monitors.count { return index }
            selectedIndex = index
            selectedCount = layout.count
        }

        return selectedIndex
    }

    static func exactArrangementIndex(for monitors: [Monitor], in arrangements: [MonitorArrangement]) -> Int? {
        guard let index = arrangementIndex(for: monitors, in: arrangements),
              arrangements[index].monitors.count == monitors.count
        else { return nil }
        return index
    }

    static func layout(for monitors: [Monitor], in arrangements: [MonitorArrangement]) -> [MonitorRoutingSettings] {
        guard let index = arrangementIndex(for: monitors, in: arrangements) else { return [] }
        return arrangements[index].monitors
    }

    static func store(
        _ layout: [MonitorRoutingSettings],
        for monitors: [Monitor],
        in arrangements: inout [MonitorArrangement]
    ) {
        guard !monitors.isEmpty else { return }
        if let index = exactArrangementIndex(for: monitors, in: arrangements) {
            arrangements[index].monitors = layout
        } else {
            arrangements.append(MonitorArrangement(monitors: layout))
        }
    }

    static func gridAdjacent(
        from source: Monitor,
        direction: Direction,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor],
        wrapAround: Bool
    ) -> Adjacency {
        guard let completeLayout = completeLayout(layout, for: monitors) else {
            return .fallBackToMacOS
        }

        let placed = zip(monitors, completeLayout).map { monitor, settings in
            PlacedMonitor(monitor: monitor, column: settings.gridColumn, row: settings.gridRow)
        }
        guard let origin = placed.first(where: { $0.monitor.id == source.id }) else {
            return .fallBackToMacOS
        }

        let line = placed.filter {
            $0.monitor.id != origin.monitor.id && $0.sharesLine(with: origin, direction: direction)
        }
        let ahead = line.filter { $0.offset(from: origin, direction: direction) > 0 }
        if let nearest = ahead.min(by: {
            $0.offset(from: origin, direction: direction) < $1.offset(from: origin, direction: direction)
        }) {
            return .monitor(nearest.monitor)
        }

        guard wrapAround, let wrapped = line.min(by: {
            $0.offset(from: origin, direction: direction) < $1.offset(from: origin, direction: direction)
        }) else {
            return .edge
        }
        return .monitor(wrapped.monitor)
    }

    static func cursorRoute(
        from source: Monitor,
        direction: Direction,
        edgeRatio: CGFloat,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor]
    ) -> CursorAdjacency {
        guard let placed = placedLayout(layout, for: monitors),
              let origin = placed.first(where: { $0.monitor.id == source.id })
        else {
            return .fallBackToMacOS
        }

        let ordered = cursorCandidates(from: origin, direction: direction, placed: placed)
            .sorted { $0.tangentCoordinate(for: direction) < $1.tangentCoordinate(for: direction) }
        guard !ordered.isEmpty else { return .edge }

        let ratio = min(max(edgeRatio, 0), 1)
        if ordered.count > 1 {
            let scaledRatio = ratio * CGFloat(ordered.count)
            let targetIndex = min(Int(scaledRatio), ordered.count - 1)
            return .route(CursorRoute(
                monitor: ordered[targetIndex].monitor,
                destinationRatio: scaledRatio - CGFloat(targetIndex)
            ))
        }

        let target = ordered[0]
        let reverseDirection: Direction = switch direction {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
        let reverse = cursorCandidates(from: target, direction: reverseDirection, placed: placed)
            .sorted {
                $0.tangentCoordinate(for: reverseDirection) < $1.tangentCoordinate(for: reverseDirection)
            }
        guard reverse.count > 1,
              let sourceIndex = reverse.firstIndex(where: { $0.monitor.id == source.id })
        else {
            return .route(CursorRoute(monitor: target.monitor, destinationRatio: ratio))
        }

        return .route(CursorRoute(
            monitor: target.monitor,
            destinationRatio: (CGFloat(sourceIndex) + ratio) / CGFloat(reverse.count)
        ))
    }

    static func cursorNeighbors(
        from source: Monitor,
        direction: Direction,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor]
    ) -> [Monitor]? {
        cursorCandidates(
            from: source,
            direction: direction,
            layout: layout,
            monitors: monitors
        )?.map(\.monitor)
    }

    private static func cursorCandidates(
        from source: Monitor,
        direction: Direction,
        layout: [MonitorRoutingSettings],
        monitors: [Monitor]
    ) -> [PlacedMonitor]? {
        guard let placed = placedLayout(layout, for: monitors),
              let origin = placed.first(where: { $0.monitor.id == source.id })
        else {
            return nil
        }
        return cursorCandidates(from: origin, direction: direction, placed: placed)
    }

    private static func placedLayout(
        _ layout: [MonitorRoutingSettings],
        for monitors: [Monitor]
    ) -> [PlacedMonitor]? {
        guard let completeLayout = completeLayout(layout, for: monitors) else { return nil }
        return zip(monitors, completeLayout).map { monitor, settings in
            PlacedMonitor(monitor: monitor, column: settings.gridColumn, row: settings.gridRow)
        }
    }

    private static func cursorCandidates(
        from origin: PlacedMonitor,
        direction: Direction,
        placed: [PlacedMonitor]
    ) -> [PlacedMonitor] {
        let candidates = placed.filter {
            $0.monitor.id != origin.monitor.id && $0.sharesCursorRoute(with: origin, direction: direction)
        }
        guard let nearestOffset = candidates.map({ $0.offset(from: origin, direction: direction) }).min() else {
            return []
        }
        return candidates.filter { $0.offset(from: origin, direction: direction) == nearestOffset }
    }

    static func completeLayout(
        _ layout: [MonitorRoutingSettings],
        for monitors: [Monitor]
    ) -> [MonitorRoutingSettings]? {
        var completeLayout: [MonitorRoutingSettings] = []
        completeLayout.reserveCapacity(monitors.count)
        var occupiedCells = Set<GridCell>()
        occupiedCells.reserveCapacity(monitors.count)

        for monitor in monitors {
            guard let settings = MonitorSettingsStore.get(for: monitor, in: layout) else {
                return nil
            }
            let cell = GridCell(column: settings.gridColumn, row: settings.gridRow)
            guard occupiedCells.insert(cell).inserted else { return nil }
            completeLayout.append(settings)
        }

        return completeLayout
    }

    static func seedLayout(from monitors: [Monitor]) -> [MonitorRoutingSettings] {
        let columns = sortedDistinct(monitors.map(\.frame.center.x), ascending: true)
        let rows = sortedDistinct(monitors.map(\.frame.center.y), ascending: false)
        return monitors.map { monitor in
            MonitorRoutingSettings(
                monitorName: monitor.name,
                monitorDisplayUUID: monitor.displayUUID,
                monitorDisplayId: monitor.displayId,
                gridColumn: columns.firstIndex(of: monitor.frame.center.x) ?? 0,
                gridRow: rows.firstIndex(of: monitor.frame.center.y) ?? 0
            )
        }
    }

    private static func sortedDistinct(_ values: [CGFloat], ascending: Bool) -> [CGFloat] {
        let unique = Array(Set(values))
        return ascending ? unique.sorted() : unique.sorted(by: >)
    }
}

private struct PlacedMonitor {
    let monitor: Monitor
    let column: Int
    let row: Int

    func sharesLine(with origin: PlacedMonitor, direction: Direction) -> Bool {
        switch direction {
        case .left,
             .right: row == origin.row
        case .up,
             .down: column == origin.column
        }
    }

    func offset(from origin: PlacedMonitor, direction: Direction) -> Int {
        switch direction {
        case .right: column - origin.column
        case .left: origin.column - column
        case .down: row - origin.row
        case .up: origin.row - row
        }
    }

    func sharesCursorRoute(with origin: PlacedMonitor, direction: Direction) -> Bool {
        let forwardOffset = offset(from: origin, direction: direction)
        guard forwardOffset > 0 else { return false }

        switch direction {
        case .left,
             .right:
            return row == origin.row
        case .up,
             .down:
            let perpendicularOffset = abs(column - origin.column)
            return perpendicularOffset == 0 || perpendicularOffset == forwardOffset
        }
    }

    func tangentCoordinate(for direction: Direction) -> CGFloat {
        switch direction {
        case .left,
             .right:
            CGFloat(row) + 0.5
        case .up,
             .down:
            CGFloat(column) + 0.5
        }
    }

}

private struct GridCell: Hashable {
    let column: Int
    let row: Int
}
