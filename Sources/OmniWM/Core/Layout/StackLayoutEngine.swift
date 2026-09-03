// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation

final class StackLayoutEngine {
    private struct WorkspaceState {
        var orderedTokens: [WindowToken] = []
        var selectedToken: WindowToken?
        var fullscreenToken: WindowToken?
    }

    private var states: [WorkspaceDescriptor.ID: WorkspaceState] = [:]
    var isMutationSanctioned = false

    func removeLayout(for workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        states.removeValue(forKey: workspaceId)
    }

    func removeWindow(_ token: WindowToken, from workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        guard var state = states[workspaceId] else { return }
        state.orderedTokens.removeAll { $0 == token }
        if state.selectedToken == token {
            state.selectedToken = state.orderedTokens.first
        }
        if state.fullscreenToken == token {
            state.fullscreenToken = nil
        }
        states[workspaceId] = state
    }

    func syncWindows(_ tokens: [WindowToken], in workspaceId: WorkspaceDescriptor.ID) {
        assertSanctionedMutation()
        let tokenSet = Set(tokens)
        var state = states[workspaceId] ?? .init()
        state.orderedTokens.removeAll { !tokenSet.contains($0) }

        var knownTokens = Set(state.orderedTokens)
        knownTokens.reserveCapacity(tokens.count)
        if state.orderedTokens.isEmpty {
            for token in tokens where knownTokens.insert(token).inserted {
                state.orderedTokens.append(token)
            }
        } else {
            for token in tokens where knownTokens.insert(token).inserted {
                state.orderedTokens.insert(token, at: 0)
            }
        }

        if state.selectedToken.map(tokenSet.contains) != true {
            state.selectedToken = state.orderedTokens.first
        }
        if state.fullscreenToken.map(tokenSet.contains) != true {
            state.fullscreenToken = nil
        }
        states[workspaceId] = state
    }

    func orderedTokens(in workspaceId: WorkspaceDescriptor.ID) -> [WindowToken] {
        states[workspaceId]?.orderedTokens ?? []
    }

    func contains(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        states[workspaceId]?.orderedTokens.contains(token) == true
    }

    func selectedToken(in workspaceId: WorkspaceDescriptor.ID) -> WindowToken? {
        states[workspaceId]?.selectedToken
    }

    func activate(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard var state = states[workspaceId], state.orderedTokens.contains(token) else { return false }
        state.selectedToken = token
        states[workspaceId] = state
        return true
    }

    func neighbor(
        of token: WindowToken,
        direction: Direction,
        among eligibleTokens: Set<WindowToken>,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        let offset: Int
        switch direction {
        case .up:
            offset = -1
        case .down:
            offset = 1
        case .left, .right:
            return nil
        }
        let tokens = orderedTokens(in: workspaceId).filter(eligibleTokens.contains)
        guard let index = tokens.firstIndex(of: token), tokens.count > 1 else { return nil }
        return tokens[(index + offset + tokens.count) % tokens.count]
    }

    func move(
        _ token: WindowToken,
        direction: Direction,
        among eligibleTokens: Set<WindowToken>,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard var state = states[workspaceId],
              let destination = neighbor(
                  of: token,
                  direction: direction,
                  among: eligibleTokens,
                  in: workspaceId
              ),
              let sourceIndex = state.orderedTokens.firstIndex(of: token),
              let destinationIndex = state.orderedTokens.firstIndex(of: destination)
        else {
            return false
        }

        state.orderedTokens.swapAt(sourceIndex, destinationIndex)
        states[workspaceId] = state
        return true
    }

    func insert(_ token: WindowToken, after anchor: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard var state = states[workspaceId],
              token != anchor,
              let sourceIndex = state.orderedTokens.firstIndex(of: token),
              let anchorIndex = state.orderedTokens.firstIndex(of: anchor)
        else {
            return false
        }
        state.orderedTokens.remove(at: sourceIndex)
        let destinationIndex = state.orderedTokens.firstIndex(of: anchor) ?? anchorIndex
        state.orderedTokens.insert(token, at: destinationIndex + 1)
        states[workspaceId] = state
        return true
    }

    func toggleFullscreen(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard var state = states[workspaceId], state.orderedTokens.contains(token) else { return false }
        state.fullscreenToken = state.fullscreenToken == token ? nil : token
        states[workspaceId] = state
        return true
    }

    func isWindowFullscreen(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        states[workspaceId]?.fullscreenToken == token
    }

    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect,
        fullscreenScreen: CGRect,
        innerGap: CGFloat
    ) -> [WindowToken: CGRect] {
        let state = states[workspaceId] ?? .init()
        let tokens = state.orderedTokens
        guard !tokens.isEmpty else { return [:] }

        if let fullscreenToken = state.fullscreenToken {
            return [fullscreenToken: fullscreenScreen]
        }

        guard tokens.count > 1 else { return [tokens[0]: screen] }

        let gap = max(0, innerGap)
        let contentWidth = max(0, screen.width - gap)
        let masterWidth = contentWidth * 0.55
        let stackWidth = contentWidth - masterWidth
        var frames = [tokens[0]: CGRect(x: screen.minX, y: screen.minY, width: masterWidth, height: screen.height)]
        let stackCount = tokens.count - 1
        let stackHeight = max(0, (screen.height - gap * CGFloat(stackCount - 1)) / CGFloat(stackCount))
        let stackX = screen.minX + masterWidth + gap

        for (index, token) in tokens.dropFirst().enumerated() {
            frames[token] = CGRect(
                x: stackX,
                y: screen.minY + CGFloat(index) * (stackHeight + gap),
                width: stackWidth,
                height: stackHeight
            )
        }
        return frames
    }

    private func assertSanctionedMutation() {
        precondition(isMutationSanctioned, "Stack layout mutation must run inside WorldStore.commit")
    }
}
