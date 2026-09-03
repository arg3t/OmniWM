// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class StackLayoutHandler {
    private var framesByWorkspace: [WorkspaceDescriptor.ID: [WindowToken: CGRect]] = [:]
    weak var controller: WMController?

    init(controller: WMController?) {
        self.controller = controller
    }

    func layoutWithStackEngine(activeWorkspaces: Set<WorkspaceDescriptor.ID>) -> [WorkspaceLayoutPlan] {
        guard let controller, let engine = controller.stackEngine else { return [] }
        var plans: [WorkspaceLayoutPlan] = []
        for workspaceId in activeWorkspaces.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let workspace = controller.workspaceManager.descriptor(for: workspaceId),
                  controller.settings.layoutType(for: workspace.name) == .stack,
                  let monitor = controller.workspaceManager.monitor(for: workspaceId),
                  let input = controller.layoutRefreshController.buildRefreshInput(
                      workspaceId: workspaceId,
                      monitor: monitor,
                      resolveConstraints: false,
                      isActiveWorkspace: controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id == workspaceId
                  )
            else {
                continue
            }
            engine.syncWindows(input.windows.map(\.token), in: workspaceId)
            let frames = engine.calculateLayout(
                for: workspaceId,
                screen: input.monitor.workingFrame,
                fullscreenScreen: input.monitor.fullscreenLayoutFrame,
                innerGap: controller.innerGap(for: monitor)
            )
            framesByWorkspace[workspaceId] = frames
            let rememberedFocusToken = controller.workspaceManager.preferredFocusToken(in: workspaceId)
                ?? engine.orderedTokens(in: workspaceId).first
            plans.append(
                WorkspaceLayoutPlan(
                    workspaceId: workspaceId,
                    monitor: input.monitor,
                    sessionPatch: WorkspaceSessionPatch(
                        workspaceId: workspaceId,
                        rememberedFocusToken: rememberedFocusToken,
                        plannedSeq: input.plannedSeq
                    ),
                    diff: layoutDiff(
                        windows: input.windows,
                        frames: frames,
                        engine: engine,
                        workspaceId: workspaceId,
                        excludedTokens: input.excludedTokens,
                        scale: input.monitor.scale,
                        canRestoreHiddenWorkspaceWindows: input.isActiveWorkspace
                    ),
                    isActiveWorkspace: input.isActiveWorkspace
                )
            )
        }

        return plans
    }
    func frame(for token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> CGRect? {
        framesByWorkspace[workspaceId]?[token]
    }

    func frames(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken: CGRect] {
        framesByWorkspace[workspaceId] ?? [:]
    }

    func hitTestFocusableWindow(point: CGPoint, in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        guard let controller else { return nil }
        let eligibleTokens = eligibleTokens(in: workspaceId)
        return controller.stackEngine?.orderedTokens(in: workspaceId).reversed().first { token in
            eligibleTokens.contains(token) && framesByWorkspace[workspaceId]?[token]?.contains(point) == true
        }
    }

    func insertWindow(_ token: WindowToken, after anchor: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller, let engine = controller.stackEngine else { return false }
        let inserted = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.insert(token, after: anchor, in: workspaceId)
        }
        guard inserted else { return false }
        controller.workspaceManager.recordLayoutOperation(.windowInserted(token: token), in: workspaceId)
        return true
    }

    func focusStack(direction: Direction) -> Bool {
        guard let controller, let engine = controller.stackEngine,
              let workspaceId = controller.activeWorkspace()?.id
        else {
            return false
        }
        let eligibleTokens = eligibleTokens(in: workspaceId)
        guard let current = engine.selectedToken(in: workspaceId)
            ?? controller.workspaceManager.lastFocusedToken(in: workspaceId)
            ?? engine.orderedTokens(in: workspaceId).first(where: eligibleTokens.contains),
              let target = engine.neighbor(
                  of: current,
                  direction: direction,
                  among: eligibleTokens,
                  in: workspaceId
              ),
              controller.workspaceManager.withEngineMutationScope(in: workspaceId, {
                  engine.activate(target, in: workspaceId)
              })
        else {
            return false
        }

        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: workspaceId,
                viewportState: nil,
                rememberedFocusToken: target,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.focusWindow(target)
        controller.surfaceReconciler.noteWorldChanged()
        return true
    }

    @discardableResult
    func moveStack(direction: Direction) -> Bool {
        guard let controller, let engine = controller.stackEngine,
              let workspaceId = controller.activeWorkspace()?.id
        else {
            return false
        }
        let eligibleTokens = eligibleTokens(in: workspaceId)
        guard let token = engine.selectedToken(in: workspaceId)
            ?? controller.workspaceManager.lastFocusedToken(in: workspaceId)
        else { return false }
        let moved = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.move(token, direction: direction, among: eligibleTokens, in: workspaceId)
        }
        guard moved else { return false }
        controller.workspaceManager.recordLayoutOperation(.windowsSwapped, in: workspaceId)
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
        return true
    }

    func toggleFullscreen() {
        guard let controller, let engine = controller.stackEngine,
              let workspaceId = controller.activeWorkspace()?.id,
              let token = engine.selectedToken(in: workspaceId)
                  ?? controller.workspaceManager.lastFocusedToken(in: workspaceId)
        else {
            return
        }
        let changed = controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            engine.toggleFullscreen(token, in: workspaceId)
        }
        guard changed else { return }
        controller.workspaceManager.recordLayoutOperation(.fullscreenToggled(token: token), in: workspaceId)
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
    }

    private func eligibleTokens(in workspaceId: WorkspaceDescriptor.ID) -> Set<WindowToken> {
        guard let controller else { return [] }
        return Set(controller.workspaceManager.tiledEntries(in: workspaceId).lazy.compactMap { entry in
            controller.isManagedWindowSuppressedByMacOSHide(entry.token) ? nil : entry.token
        })
    }

    private func layoutDiff(
        windows: [LayoutWindowSnapshot],
        frames: [WindowToken: CGRect],
        engine: StackLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        excludedTokens: Set<WindowToken>,
        scale: CGFloat,
        canRestoreHiddenWorkspaceWindows: Bool
    ) -> WorkspaceLayoutDiff {
        var diff = WorkspaceLayoutDiff()
        for window in windows {
            let token = window.token
            let frame = frames[token]
            if window.isNativeFullscreenSuspended {
                if let originalToken = window.nativeFullscreenOriginalToken {
                    let validFrame = frame.map { !$0.isNull && !$0.isInfinite && $0.width > 1 && $0.height > 1 } == true
                    diff.nativeFullscreenSlots[originalToken] = NativeFullscreenSlotProjection(
                        currentToken: token,
                        frame: validFrame ? frame ?? .zero : .zero,
                        visible: canRestoreHiddenWorkspaceWindows && !excludedTokens.contains(token) && validFrame
                    )
                }
                continue
            }
            if excludedTokens.contains(token) {
                continue
            }
            if window.hiddenState?.offscreenSide != nil, frame != nil {
                diff.visibilityChanges.append(.show(token))
            }
            if canRestoreHiddenWorkspaceWindows,
               let hiddenState = window.hiddenState,
               hiddenState.workspaceInactive
            {
                diff.restoreChanges.append(.init(token: token, hiddenState: hiddenState))
            }
            guard let frame else { continue }
            diff.frameChanges.append(
                LayoutFrameChange(
                    token: token,
                    frame: frame.roundedToPhysicalPixels(scale: scale),
                    forceApply: engine.isWindowFullscreen(token, in: workspaceId)
                )
            )
        }
        return diff
    }
}
