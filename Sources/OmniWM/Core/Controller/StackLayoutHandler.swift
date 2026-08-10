// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor final class StackLayoutHandler {
    weak var controller: WMController?

    var stackAnimationByDisplay: [CGDirectDisplayID: (WorkspaceDescriptor.ID, Monitor)] = [:]

    init(controller: WMController?) {
        self.controller = controller
    }

    func registerStackAnimation(
        _ workspaceId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        on displayId: CGDirectDisplayID
    ) -> Bool {
        if stackAnimationByDisplay[displayId]?.0 == workspaceId {
            return false
        }
        stackAnimationByDisplay[displayId] = (workspaceId, monitor)
        return true
    }

    func hasStackAnimationRunning(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        stackAnimationByDisplay.values.contains { $0.0 == workspaceId }
    }

    @discardableResult
    func applyFramesOnDemand(workspaceId wsId: WorkspaceDescriptor.ID, monitor: Monitor) -> Bool {
        guard let controller,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.stackEngine,
              let snapshot = makeWorkspaceSnapshot(
                  workspaceId: wsId,
                  monitor: monitor,
                  resolveConstraints: false,
                  isActiveWorkspace: activeWorkspaceId == wsId
              )
        else {
            return false
        }

        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine
        )
        return controller.layoutRefreshController.executeLayoutPlan(plan)
    }

    func refreshEngineConstraints(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller,
              let engine = controller.stackEngine,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let refreshInput = controller.layoutRefreshController.buildRefreshInput(
                  workspaceId: workspaceId,
                  monitor: monitor,
                  resolveConstraints: true,
                  isActiveWorkspace: activeWorkspaceId == workspaceId
              )
        else {
            return
        }

        controller.workspaceManager.withEngineMutationScope {
            for window in refreshInput.windows {
                engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
            }
        }
    }

    func tickStackAnimation(targetTime: CFTimeInterval, displayId: CGDirectDisplayID) {
        guard let (wsId, _) = stackAnimationByDisplay[displayId] else { return }
        guard let controller, let engine = controller.stackEngine else {
            controller?.layoutRefreshController.stopStackAnimation(for: displayId)
            return
        }

        guard let monitor = controller.workspaceManager.monitors.first(where: { $0.displayId == displayId }) else {
            controller.layoutRefreshController.stopStackAnimation(for: displayId)
            return
        }

        guard controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId else {
            controller.layoutRefreshController.stopStackAnimation(for: displayId)
            return
        }

        engine.tickAnimations(at: targetTime, in: wsId)
        guard let snapshot = makeWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: false,
            isActiveWorkspace: true
        ) else {
            return
        }

        let plan = buildAnimationPlan(
            snapshot: snapshot,
            engine: engine,
            targetTime: targetTime
        )
        let didExecute = controller.layoutRefreshController.executeLayoutPlan(plan)
        guard didExecute else {
            controller.layoutRefreshController.requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: [wsId]
            )
            return
        }

        if !engine.hasActiveAnimations(in: wsId, at: targetTime) {
            if let settleSnapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                resolveConstraints: false,
                isActiveWorkspace: true
            ) {
                var settlePlan = buildAnimationPlan(
                    snapshot: settleSnapshot,
                    engine: engine,
                    targetTime: targetTime
                )
                settlePlan.isAnimationTick = false
                _ = controller.layoutRefreshController.executeLayoutPlan(settlePlan)
            }
            controller.layoutRefreshController.stopStackAnimation(for: displayId)
            controller.surfaceReconciler.noteRestackOccurred()
        }
    }

    func layoutWithStackEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.stackEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        let workspaceIds = activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString })
        for wsId in workspaceIds {
            guard let workspace = controller.workspaceManager.descriptor(for: wsId),
                  let monitor = controller.workspaceManager.monitor(for: wsId)
            else { continue }

            let wsName = workspace.name
            let layoutType = controller.settings.layoutType(for: wsName)
            guard layoutType == .stack else { continue }
            let isActiveWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == wsId

            guard let snapshot = makeWorkspaceSnapshot(
                workspaceId: wsId,
                monitor: monitor,
                resolveConstraints: true,
                isActiveWorkspace: isActiveWorkspace
            ) else { continue }

            plans.append(
                buildRelayoutPlan(
                    snapshot: snapshot,
                    engine: engine
                )
            )
        }

        return plans
    }

    func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command
    ) {
        controller?.workspaceManager.recordLayoutOperation(operation, in: workspaceId, source: source)
    }

    // MARK: - Stack-specific commands

    func adjustNmaster(by delta: Int) {
        guard let controller else { return }
        withStackContext { engine, wsId in
            engine.adjustNmaster(by: delta, in: wsId)
            recordLayoutOperation(.splitRatioChanged, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func zoom() {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if engine.zoomWindow(in: wsId) {
                recordLayoutOperation(.windowsSwapped, in: wsId)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func focusStackNext() {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if let token = engine.activateWindow_next(in: wsId) {
                controller.focusWindow(token)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func focusStackPrevious() {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if let token = engine.activateWindow_previous(in: wsId) {
                controller.focusWindow(token)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func moveStackNext() {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if engine.moveWindowNext(in: wsId) {
                recordLayoutOperation(.windowsSwapped, in: wsId)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func moveStackPrevious() {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if engine.moveWindowPrevious(in: wsId) {
                recordLayoutOperation(.windowsSwapped, in: wsId)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func toggleStackOrientation() {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if engine.toggleOrientation(in: wsId) {
                recordLayoutOperation(.splitOrientationToggled, in: wsId)
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    // MARK: - Layout Engine Configuration

    func enableStackLayout() {
        guard let controller else { return }
        let engine = StackLayoutEngine()
        engine.animationClock = controller.animationClock
        controller.stackEngine = engine
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func updateStackConfig(
        masterRatio: CGFloat? = nil,
        stackOrientation: StackOrientation? = nil,
        nmaster: Int? = nil,
        innerGap: CGFloat? = nil
    ) {
        guard let controller, let engine = controller.stackEngine else { return }
        controller.workspaceManager.withEngineMutationScope {
            if let v = masterRatio { engine.settings.masterRatio = v }
            if let v = stackOrientation { engine.settings.stackOrientation = v }
            if let v = nmaster { engine.settings.nmaster = v }
            if let v = innerGap { engine.settings.innerGap = v }
        }
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func withStackContext(
        perform: (StackLayoutEngine, WorkspaceDescriptor.ID) -> Void
    ) {
        guard let controller,
              let engine = controller.stackEngine,
              let wsId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: wsId)
        else { return }
        controller.workspaceManager.withEngineMutationScope {
            applyResolvedSettings(controller.settings.resolvedStackSettings(for: monitor), to: engine)
            perform(engine, wsId)
        }
    }

    private func makeWorkspaceSnapshot(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        resolveConstraints: Bool,
        isActiveWorkspace: Bool
    ) -> StackWorkspaceSnapshot? {
        guard let controller else { return nil }

        guard let refreshInput = controller.layoutRefreshController.buildRefreshInput(
            workspaceId: wsId,
            monitor: monitor,
            resolveConstraints: resolveConstraints,
            isActiveWorkspace: isActiveWorkspace
        ) else {
            return nil
        }
        return StackWorkspaceSnapshot(
            workspaceId: wsId,
            monitor: refreshInput.monitor,
            windows: refreshInput.windows,
            preferredFocusToken: controller.workspaceManager.preferredFocusToken(in: wsId),
            preferredHideSide: controller.layoutRefreshController.preferredHideSide(for: monitor),
            settings: controller.settings.resolvedStackSettings(for: monitor),
            isActiveWorkspace: refreshInput.isActiveWorkspace
        )
    }

    private func buildRelayoutPlan(
        snapshot: StackWorkspaceSnapshot,
        engine: StackLayoutEngine
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)

        let now = controller?.animationClock.now() ?? CACurrentMediaTime()
        var previousTargetFrames = engine.currentFrames(in: snapshot.workspaceId)
        var oldFrames = engine.presentedFrames(in: snapshot.workspaceId, at: now)
        engine.consumePendingMovementFrameSeeds(
            in: snapshot.workspaceId,
            oldFrames: &oldFrames,
            previousTargetFrames: &previousTargetFrames
        )
        let windowTokens = snapshot.windows.map(\.token)
        let removedTokens = engine.syncWindows(
            windowTokens,
            in: snapshot.workspaceId,
            focusedToken: snapshot.preferredFocusToken,
            bootstrapScreen: snapshot.monitor.workingFrame,
            bootstrapFullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )

        for window in snapshot.windows {
            engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
        }

        let newFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            fullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )
        if !removedTokens.isEmpty {
            controller?.windowActionHandler.refreshOverviewProjection(
                affectedWorkspaceIds: [snapshot.workspaceId],
                selectedToken: engine.activeToken(in: snapshot.workspaceId)
            )
        }

        let rememberedFocusToken = engine.activeToken(in: snapshot.workspaceId)

        engine.animateWindowMovements(
            oldFrames: oldFrames,
            previousTargetFrames: previousTargetFrames,
            newFrames: newFrames,
            in: snapshot.workspaceId,
            startTime: now,
            motion: controller?.motionPolicy.snapshot() ?? .enabled
        )

        let animationsActive = engine.hasActiveAnimations(in: snapshot.workspaceId, at: now)
        let diffFrames = animationsActive
            ? engine.calculateAnimatedFrames(
                baseFrames: newFrames,
                in: snapshot.workspaceId,
                at: now
            )
            : newFrames
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: diffFrames,
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: true,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIds ?? []
        )
        let directives: [AnimationDirective] = animationsActive
            ? [.startStackAnimation(workspaceId: snapshot.workspaceId, monitorId: snapshot.monitor.monitorId)]
            : []

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId,
                rememberedFocusToken: rememberedFocusToken
            ),
            diff: diff,
            animationDirectives: directives,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    private func buildOnDemandLayoutPlan(
        snapshot: StackWorkspaceSnapshot,
        engine: StackLayoutEngine
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)

        let frames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            fullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: frames,
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: true,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIds ?? []
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId
            ),
            diff: diff,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    private func buildAnimationPlan(
        snapshot: StackWorkspaceSnapshot,
        engine: StackLayoutEngine,
        targetTime: TimeInterval
    ) -> WorkspaceLayoutPlan {
        applyResolvedSettings(snapshot.settings, to: engine)

        let baseFrames = engine.calculateLayout(
            for: snapshot.workspaceId,
            screen: snapshot.monitor.workingFrame,
            fullscreenScreen: snapshot.monitor.fullscreenLayoutFrame
        )
        let animatedFrames = engine.calculateAnimatedFrames(
            baseFrames: baseFrames,
            in: snapshot.workspaceId,
            at: targetTime
        )
        let diff = layoutDiff(
            windows: snapshot.windows,
            frames: animatedFrames,
            engine: engine,
            workspaceId: snapshot.workspaceId,
            preferredHideSide: snapshot.preferredHideSide,
            canRestoreHiddenWorkspaceWindows: snapshot.isActiveWorkspace,
            scale: snapshot.monitor.scale,
            reassertHidden: false,
            pendingParkWindowIds: controller?.axManager.pendingParkWindowIds ?? []
        )

        return WorkspaceLayoutPlan(
            workspaceId: snapshot.workspaceId,
            monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(
                workspaceId: snapshot.workspaceId
            ),
            diff: diff,
            isAnimationTick: true,
            isActiveWorkspace: snapshot.isActiveWorkspace
        )
    }

    func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        engine: StackLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        preferredHideSide: HideSide,
        canRestoreHiddenWorkspaceWindows: Bool,
        scale: CGFloat,
        reassertHidden: Bool,
        pendingParkWindowIds: Set<Int>
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        let effectiveScale = max(scale, 1.0)
        for window in windows {
            let token = window.token
            if window.isNativeFullscreenSuspended {
                continue
            }
            let previousOffscreenSide = window.hiddenState?.offscreenSide
            if previousOffscreenSide != nil, frames[token] != nil {
                diff.visibilityChanges.append(.show(token))
            }

            if canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(
                    .init(token: token, hiddenState: hiddenState)
                )
            }
            guard let frame = frames[token]?.roundedToPhysicalPixels(scale: effectiveScale) else { continue }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: token,
                    frame: frame,
                    forceApply: engine.isWindowFullscreen(token, in: workspaceId)
                )
            )
        }

        return diff
    }

    private func applyResolvedSettings(
        _ settings: ResolvedStackSettings,
        to engine: StackLayoutEngine
    ) {
        engine.settings.masterRatio = settings.masterRatio
        engine.settings.stackOrientation = settings.stackOrientation
        engine.settings.nmaster = settings.nmaster
        engine.settings.innerGap = settings.innerGap
    }
}

extension StackLayoutHandler: LayoutFocusable, LayoutSizable {
    func focusNeighbor(direction: Direction) -> Bool {
        guard let controller else { return false }
        var didMove = false
        withStackContext { engine, wsId in
            guard let token = engine.moveFocus(direction: direction, in: wsId) else { return }
            didMove = true
            _ = controller.workspaceManager.applySessionPatch(
                .init(
                    workspaceId: wsId,
                    viewportState: nil,
                    rememberedFocusToken: token,
                    plannedSeq: controller.workspaceManager.worldSeq
                )
            )
            controller.focusWindow(token)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return didMove
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if engine.cycleSplitRatio(forward: forward, in: wsId) {
                recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withStackContext { engine, wsId in
            if engine.balanceSizes(in: wsId) {
                recordLayoutOperation(.sizesBalanced, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }
}
