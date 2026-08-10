// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

final class StackLayoutEngine {
    private var states: [WorkspaceDescriptor.ID: StackWorkspaceState] = [:]
    private var windowConstraints: [WindowToken: WindowSizeConstraints] = [:]

    var settings: StackSettings = StackSettings()
    private var monitorSettings: [Monitor.ID: ResolvedStackSettings] = [:]
    var animationClock: AnimationClock?
    var isMutationSanctioned = true

    func assertSanctionedMutation(_ operation: StaticString = #function) {
        assert(
            isMutationSanctioned,
            "\(operation) mutated the Stack layout tree outside a sanctioned WorldStore scope"
        )
    }

    func updateWindowConstraints(for token: WindowToken, constraints: WindowSizeConstraints) {
        assertSanctionedMutation()
        windowConstraints[token] = constraints.normalized()
    }

    func constraints(for token: WindowToken) -> WindowSizeConstraints {
        windowConstraints[token] ?? .unconstrained
    }

    func updateMonitorSettings(_ resolved: ResolvedStackSettings, for monitorId: Monitor.ID) {
        assertSanctionedMutation()
        monitorSettings[monitorId] = resolved
    }

    func cleanupRemovedMonitor(_ monitorId: Monitor.ID) {
        assertSanctionedMutation()
        monitorSettings.removeValue(forKey: monitorId)
    }

    func effectiveSettings(for monitorId: Monitor.ID) -> StackSettings {
        guard let resolved = monitorSettings[monitorId] else { return settings }

        var effective = settings
        effective.nmaster = resolved.nmaster
        effective.mfact = resolved.mfact
        effective.resizeStep = resolved.resizeStep
        effective.singleWindowFit = resolved.singleWindowFit
        if !resolved.useGlobalGaps {
            effective.innerGap = resolved.innerGap
        }
        return effective
    }

    var windowMovementAnimationConfig: CubicConfig = .hyprlandDwindle

    func root(for workspaceId: WorkspaceDescriptor.ID) -> StackNode? {
        states[workspaceId]?.root
    }

    private func ensureState(for workspaceId: WorkspaceDescriptor.ID) -> StackWorkspaceState {
        if let existing = states[workspaceId] {
            return existing
        }
        let state = StackWorkspaceState()
        states[workspaceId] = state
        return state
    }

    func removeLayout(for workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = states.removeValue(forKey: workspaceId) else { return }
        for token in state.leafByToken.keys {
            releaseConstraintsIfUntracked(token)
        }
    }

    private func releaseConstraintsIfUntracked(_ token: WindowToken) {
        guard states.values.allSatisfy({ $0.leafByToken[token] == nil }) else { return }
        windowConstraints.removeValue(forKey: token)
    }

    func containsWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        states[workspaceId]?.leafByToken[token] != nil
    }

    func findNode(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> StackNode? {
        states[workspaceId]?.leafByToken[token]
    }

    func isWindowFullscreen(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        findNode(for: token, in: workspaceId)?.tile?.member(for: token)?.isFullscreen == true
    }

    func fullscreenTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let state = states[workspaceId] else { return [] }
        return Set(state.leafByToken.keys.filter { token in
            state.leafByToken[token]?.tile?.member(for: token)?.isFullscreen == true
        })
    }

    func windowCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        states[workspaceId]?.leafByToken.count ?? 0
    }

    func tileCount(in workspaceId: WorkspaceDescriptor.ID) -> Int {
        states[workspaceId]?.tileCount ?? 0
    }

    func activeWindowTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let state = states[workspaceId] else { return [] }
        var tokens: Set<WindowToken> = []
        tokens.reserveCapacity(state.tileCount)
        for (token, leaf) in state.leafByToken where leaf.windowToken == token {
            tokens.insert(token)
        }
        return tokens
    }

    func inactiveGroupTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let state = states[workspaceId] else { return [] }
        var tokens: Set<WindowToken> = []
        tokens.reserveCapacity(max(0, state.leafByToken.count - state.tileCount))
        for (token, leaf) in state.leafByToken where leaf.windowToken != token {
            if leaf.tile?.isGrouped == true {
                tokens.insert(token)
            }
        }
        return tokens
    }

    func selectedNode(in workspaceId: WorkspaceDescriptor.ID) -> StackNode? {
        guard let state = states[workspaceId], let nodeId = state.selectedNodeId else { return nil }
        return findNodeById(nodeId, in: state.root)
    }

    func setSelectedNode(_ node: StackNode?, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let node else {
            ensureState(for: workspaceId).selectedNodeId = nil
            return
        }
        guard let state = states[workspaceId], findNodeById(node.id, in: state.root) != nil else { return }
        state.selectedNodeId = node.id
    }

    private func findNodeById(_ nodeId: StackNodeId, in root: StackNode) -> StackNode? {
        if root.id == nodeId { return root }
        for child in root.children {
            if let found = findNodeById(nodeId, in: child) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    func addWindow(
        token: WindowToken,
        to workspaceId: WorkspaceDescriptor.ID,
        activeWindowFrame: CGRect?
    ) -> StackNode {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)

        if let existing = state.leafByToken[token] {
            _ = existing.tile?.activate(token)
            state.selectedNodeId = existing.id
            return existing
        }

        let tile = StackTile(token: token)
        let leaf = StackNode(kind: .tile(tile))
        state.leafByToken[token] = leaf
        state.tileCount += 1
        state.selectedNodeId = leaf.id

        let currentMasterCount = state.masterNodes.count
        if currentMasterCount < settings.nmaster {
            let masterArea = ensureMasterArea(state: state)
            masterArea.appendChild(leaf)
        } else {
            let stackArea = ensureStackArea(state: state)
            stackArea.appendChild(leaf)
        }

        if let frame = activeWindowFrame {
            leaf.cachedFrame = frame
            leaf.cachedContentFrame = frame
        }

        return leaf
    }

    private func ensureMasterArea(state: StackWorkspaceState) -> StackNode {
        if let existing = state.root.children.first(where: {
            if case .masterArea = $0.kind { return true }
            return false
        }) {
            return existing
        }
        let masterArea = StackNode(kind: .masterArea)
        masterArea.parent = state.root
        state.root.children.insert(masterArea, at: 0)
        return masterArea
    }

    private func ensureStackArea(state: StackWorkspaceState) -> StackNode {
        if let existing = state.root.children.first(where: {
            if case .stackArea = $0.kind { return true }
            return false
        }) {
            return existing
        }
        let stackArea = StackNode(kind: .stackArea)
        stackArea.parent = state.root
        state.root.children.append(stackArea)
        return stackArea
    }

    func removeWindow(token: WindowToken, from workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let leaf = state.leafByToken[token],
              let tile = leaf.tile
        else { return }

        state.leafByToken.removeValue(forKey: token)
        state.tileCount -= 1
        state.pendingMovementFrameSeeds.removeValue(forKey: token)

        let parent = leaf.parent
        leaf.detach()

        if let parent, parent.children.isEmpty {
            if case .masterArea = parent.kind {
                parent.detach()
            }
        }

        if state.leafByToken.isEmpty {
            state.selectedNodeId = nil
        } else if state.selectedNodeId == leaf.id {
            state.selectedNodeId = state.orderedNodes.first?.id
        }

        releaseConstraintsIfUntracked(token)
    }

    @discardableResult
    func rekeyWindow(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard oldToken != newToken,
              let state = states[workspaceId],
              state.leafByToken[newToken] == nil,
              let leaf = state.leafByToken[oldToken],
              let tile = leaf.tile
        else {
            return false
        }

        guard tile.rekey(from: oldToken, to: newToken) else { return false }
        state.leafByToken.removeValue(forKey: oldToken)
        state.leafByToken[newToken] = leaf
        if let seed = state.pendingMovementFrameSeeds.removeValue(forKey: oldToken) {
            state.pendingMovementFrameSeeds[newToken] = seed
        }
        if let constraints = windowConstraints[oldToken] {
            windowConstraints[newToken] = constraints
        }
        releaseConstraintsIfUntracked(oldToken)
        return true
    }

    func activeToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        selectedNode(in: workspaceId)?.windowToken
    }

    @discardableResult
    func activateWindow(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        activateWindowOutcome(token, in: workspaceId) == .activated
    }

    @discardableResult
    func activateWindowOutcome(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> StackWindowActivationOutcome {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let leaf = state.leafByToken[token],
              let tile = leaf.tile
        else {
            return .missing
        }

        state.selectedNodeId = leaf.id
        return tile.activate(token) ? .activated : .selected
    }

    func setNmaster(_ count: Int, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)
        let clamped = max(0, count)
        guard clamped != settings.nmaster else { return }
        settings.nmaster = clamped
        rebalanceAreas(state: state)
    }

    func adjustNmaster(by delta: Int, in workspaceId: WorkspaceDescriptor.ID) {
        setNmaster(settings.nmaster + delta, in: workspaceId)
    }

    func setMfact(_ ratio: CGFloat, in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        let state = ensureState(for: workspaceId)
        let clamped = settings.clampedMfact(ratio)
        guard clamped != settings.mfact else { return }
        settings.mfact = clamped
        _ = state
    }

    func adjustMfact(by delta: CGFloat, in workspaceId: WorkspaceDescriptor.ID) {
        setMfact(settings.mfact + delta, in: workspaceId)
    }

    @discardableResult
    func zoomWindow(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let selectedId = state.selectedNodeId,
              let selected = findNodeById(selectedId, in: state.root),
              let selectedIndex = state.nodeIndex(selected),
              selectedIndex > 0
        else { return false }

        guard let first = state.orderedNodes.first,
              let firstParent = first.parent,
              let firstIndex = firstParent.children.firstIndex(where: { $0.id == first.id }),
              let selectedParent = selected.parent,
              let selectedIndexInParent = selectedParent.children.firstIndex(where: { $0.id == selected.id })
        else { return false }

        selected.detach()
        firstParent.insertChild(selected, at: firstIndex)
        if selectedParent.children.contains(where: { $0.id == first.id }) {
            first.detach()
            selectedParent.insertChild(first, at: selectedIndexInParent)
        }

        state.selectedNodeId = selected.id
        return true
    }

    @discardableResult
    func moveWindow(direction: Direction, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let selectedId = state.selectedNodeId,
              let selected = findNodeById(selectedId, in: state.root),
              let index = state.nodeIndex(selected)
        else { return false }

        let ordered = state.orderedNodes
        guard ordered.count > 1 else { return false }

        let newIndex: Int
        switch direction {
        case .left, .up:
            newIndex = max(0, index - 1)
        case .right, .down:
            newIndex = min(ordered.count - 1, index + 1)
        }
        guard newIndex != index else { return false }

        let movementFrameSeed = selected.presentedFrame(
            at: animationClock?.now() ?? CACurrentMediaTime()
        )

        selected.detach()
        let targetNode = ordered[newIndex]
        let targetParent = targetNode.parent!
        let targetIndexInParent = targetParent.children.firstIndex(where: { $0.id == targetNode.id })!

        if newIndex < index {
            targetParent.insertChild(selected, at: targetIndexInParent)
        } else {
            targetParent.insertChild(selected, at: targetIndexInParent + 1)
        }

        rebalanceAreas(state: state)

        if state.pendingMovementFrameSeeds[selected.windowToken!] == nil {
            state.pendingMovementFrameSeeds[selected.windowToken!] = movementFrameSeed
        }

        return true
    }

    @discardableResult
    func toggleFullscreen(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = states[workspaceId],
              let leaf = state.leafByToken[token],
              let tile = leaf.tile
        else { return false }

        return tile.toggleFullscreen(for: token)
    }

    private func rebalanceAreas(state: StackWorkspaceState) {
        let allNodes = state.root.allTileNodes()
        guard !allNodes.isEmpty else { return }

        let masterCount = min(settings.nmaster, allNodes.count)
        let stackCount = allNodes.count - masterCount

        let masterArea = ensureMasterArea(state: state)
        let stackArea = ensureStackArea(state: state)

        var masters: [StackNode] = []
        var stacks: [StackNode] = []

        for (index, node) in allNodes.enumerated() {
            if index < masterCount {
                masters.append(node)
            } else {
                stacks.append(node)
            }
        }

        for node in allNodes {
            node.detach()
        }

        masterArea.children = masters
        for node in masterArea.children { node.parent = masterArea }

        if stackCount > 0 {
            stackArea.children = stacks
            for node in stackArea.children { node.parent = stackArea }
        } else {
            stackArea.detach()
        }

        if masterCount == 0 {
            masterArea.detach()
        }
    }

    func computeFrames(
        in workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        gaps: CGFloat
    ) -> [WindowToken: CGRect] {
        guard let state = states[workspaceId] else { return [:] }

        let masters = state.masterNodes
        let stacks = state.stackNodes
        let allWindows = state.orderedNodes

        guard !allWindows.isEmpty else { return [:] }

        let innerGap = settings.innerGap
        var output: [WindowToken: CGRect] = [:]

        if allWindows.count == 1 {
            let node = allWindows[0]
            if let tile = node.tile {
                let frame = singleWindowFrame(
                    screen: monitorFrame,
                    fit: settings.singleWindowFit
                )
                node.cachedFrame = frame
                node.cachedContentFrame = frame
                if let activeToken = tile.members.first?.token {
                    output[activeToken] = frame
                }
            }
            return output
        }

        let masterCount = masters.count
        let stackCount = stacks.count

        let masterAreaFrame: CGRect
        let stackAreaFrame: CGRect

        if stackCount == 0 {
            masterAreaFrame = monitorFrame
            stackAreaFrame = .zero
        } else if masterCount == 0 {
            masterAreaFrame = .zero
            stackAreaFrame = monitorFrame
        } else {
            switch settings.stackOrientation {
            case .vertical:
                let masterWidth = monitorFrame.width * settings.mfact
                let stackWidth = monitorFrame.width - masterWidth - innerGap
                masterAreaFrame = CGRect(
                    x: monitorFrame.minX,
                    y: monitorFrame.minY,
                    width: masterWidth,
                    height: monitorFrame.height
                )
                stackAreaFrame = CGRect(
                    x: monitorFrame.minX + masterWidth + innerGap,
                    y: monitorFrame.minY,
                    width: stackWidth,
                    height: monitorFrame.height
                )
            case .horizontal:
                let masterHeight = monitorFrame.height * settings.mfact
                let stackHeight = monitorFrame.height - masterHeight - innerGap
                masterAreaFrame = CGRect(
                    x: monitorFrame.minX,
                    y: monitorFrame.minY,
                    width: monitorFrame.width,
                    height: masterHeight
                )
                stackAreaFrame = CGRect(
                    x: monitorFrame.minX,
                    y: monitorFrame.minY + masterHeight + innerGap,
                    width: monitorFrame.width,
                    height: stackHeight
                )
            }
        }

        if masterCount > 0 {
            for (index, node) in masters.enumerated() {
                let frame: CGRect
                switch settings.stackOrientation {
                case .vertical:
                    let height = (masterAreaFrame.height - CGFloat(masterCount - 1) * innerGap) / CGFloat(masterCount)
                    frame = CGRect(
                        x: masterAreaFrame.minX,
                        y: masterAreaFrame.minY + CGFloat(index) * (height + innerGap),
                        width: masterAreaFrame.width,
                        height: height
                    )
                case .horizontal:
                    let width = (masterAreaFrame.width - CGFloat(masterCount - 1) * innerGap) / CGFloat(masterCount)
                    frame = CGRect(
                        x: masterAreaFrame.minX + CGFloat(index) * (width + innerGap),
                        y: masterAreaFrame.minY,
                        width: width,
                        height: masterAreaFrame.height
                    )
                }
                node.cachedFrame = frame.insetBy(dx: gaps, dy: gaps)
                node.cachedContentFrame = frame.insetBy(dx: gaps, dy: gaps)
                if let token = node.tile?.activeToken {
                    output[token] = node.cachedContentFrame!
                }
            }
        }

        if stackCount > 0 {
            for (index, node) in stacks.enumerated() {
                let frame: CGRect
                switch settings.stackOrientation {
                case .vertical:
                    let height = (stackAreaFrame.height - CGFloat(stackCount - 1) * innerGap) / CGFloat(stackCount)
                    frame = CGRect(
                        x: stackAreaFrame.minX,
                        y: stackAreaFrame.minY + CGFloat(index) * (height + innerGap),
                        width: stackAreaFrame.width,
                        height: height
                    )
                case .horizontal:
                    let width = (stackAreaFrame.width - CGFloat(stackCount - 1) * innerGap) / CGFloat(stackCount)
                    frame = CGRect(
                        x: stackAreaFrame.minX + CGFloat(index) * (width + innerGap),
                        y: stackAreaFrame.minY,
                        width: width,
                        height: stackAreaFrame.height
                    )
                }
                node.cachedFrame = frame.insetBy(dx: gaps, dy: gaps)
                node.cachedContentFrame = frame.insetBy(dx: gaps, dy: gaps)
                if let token = node.tile?.activeToken {
                    output[token] = node.cachedContentFrame!
                }
            }
        }

        for node in allWindows {
            if let tile = node.tile, tile.activeMember.isFullscreen {
                node.cachedFrame = monitorFrame
                node.cachedContentFrame = monitorFrame
                output[node.tile!.activeToken] = monitorFrame
            }
        }

        return output
    }

    private func singleWindowFrame(screen: CGRect, fit: SingleWindowFit) -> CGRect {
        fit.frame(in: screen)
    }

    func stackTopology(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken] {
        guard let state = states[workspaceId] else { return [] }
        return state.orderedNodes.compactMap { $0.tile?.activeToken }
    }

    func tileFrame(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> CGRect? {
        findNode(for: token, in: workspaceId)?.cachedFrame
    }

    func contentFrame(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> CGRect? {
        findNode(for: token, in: workspaceId)?.cachedContentFrame
    }

    func tickAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID) {
        guard let root = states[workspaceId]?.root else { return }
        tickAnimationsRecursive(node: root, at: time)
    }

    private func tickAnimationsRecursive(node: StackNode, at time: TimeInterval) {
        node.tickAnimations(at: time)
        for child in node.children {
            tickAnimationsRecursive(node: child, at: time)
        }
    }

    func hasActiveAnimations(at time: TimeInterval, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let root = states[workspaceId]?.root else { return false }
        return hasActiveAnimationsRecursive(node: root, at: time)
    }

    private func hasActiveAnimationsRecursive(node: StackNode, at time: TimeInterval) -> Bool {
        if node.hasActiveAnimations(at: time) { return true }
        for child in node.children {
            if hasActiveAnimationsRecursive(node: child, at: time) { return true }
        }
        return false
    }

    func consumePendingMovementFrameSeeds(
        in workspaceId: WorkspaceDescriptor.ID,
        oldFrames: inout [WindowToken: CGRect],
        previousTargetFrames: inout [WindowToken: CGRect]
    ) {
        guard let state = states[workspaceId], !state.pendingMovementFrameSeeds.isEmpty else { return }
        for (token, frame) in state.pendingMovementFrameSeeds {
            oldFrames[token] = frame
            previousTargetFrames[token] = frame
        }
        state.pendingMovementFrameSeeds.removeAll(keepingCapacity: true)
    }

    func currentFrames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGRect] {
        guard let root = states[workspaceId]?.root else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        collectCurrentFrames(node: root, into: &frames)
        return frames
    }

    private func collectCurrentFrames(node: StackNode, into frames: inout [WindowToken: CGRect]) {
        if let handle = node.windowToken, let frame = node.cachedContentFrame ?? node.cachedFrame {
            frames[handle] = frame
        }
        for child in node.children {
            collectCurrentFrames(node: child, into: &frames)
        }
    }

    func presentedFrames(in workspaceId: WorkspaceDescriptor.ID, at time: TimeInterval) -> [WindowToken: CGRect] {
        guard let root = states[workspaceId]?.root else { return [:] }
        var frames: [WindowToken: CGRect] = [:]
        collectPresentedFrames(node: root, at: time, into: &frames)
        return frames
    }

    private func collectPresentedFrames(
        node: StackNode,
        at time: TimeInterval,
        into frames: inout [WindowToken: CGRect]
    ) {
        if let handle = node.windowToken, let frame = node.presentedFrame(at: time) {
            frames[handle] = frame
        }
        for child in node.children {
            collectPresentedFrames(node: child, at: time, into: &frames)
        }
    }
}

private extension StackNode {
    func allTileNodes() -> [StackNode] {
        var result: [StackNode] = []
        collectTileNodes(node: self, into: &result)
        return result
    }

    private func collectTileNodes(node: StackNode, into result: inout [StackNode]) {
        if case .tile = node.kind {
            result.append(node)
        }
        for child in node.children {
            collectTileNodes(node: child, into: &result)
        }
    }
}
