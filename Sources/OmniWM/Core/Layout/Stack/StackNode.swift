// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

typealias StackNodeId = UUID
typealias StackTileId = UUID

struct StackTileMember: Equatable {
    var token: WindowToken
    var isFullscreen: Bool
}

final class StackTile {
    let id: StackTileId
    private(set) var members: [StackTileMember]
    private(set) var activeIndex: Int

    init(token: WindowToken, fullscreen: Bool = false) {
        id = UUID()
        members = [StackTileMember(token: token, isFullscreen: fullscreen)]
        activeIndex = 0
    }

    var activeMember: StackTileMember {
        members[activeIndex]
    }

    var activeToken: WindowToken {
        activeMember.token
    }

    var isGrouped: Bool {
        members.count > 1
    }

    func memberIndex(for token: WindowToken) -> Int? {
        members.firstIndex { $0.token == token }
    }

    func member(for token: WindowToken) -> StackTileMember? {
        memberIndex(for: token).map { members[$0] }
    }

    @discardableResult
    func activate(_ token: WindowToken) -> Bool {
        guard let index = memberIndex(for: token), index != activeIndex else { return false }
        activeIndex = index
        return true
    }

    func insertAfterActive(_ member: StackTileMember) {
        let insertionIndex = activeIndex + 1
        members.insert(member, at: insertionIndex)
        activeIndex = insertionIndex
    }

    func remove(at index: Int) -> StackTileMember {
        precondition(members.count > 1 && members.indices.contains(index))
        let member = members.remove(at: index)
        if index < activeIndex {
            activeIndex -= 1
        } else if index == activeIndex {
            activeIndex = min(index, members.count - 1)
        }
        return member
    }

    @discardableResult
    func rekey(from oldToken: WindowToken, to newToken: WindowToken) -> Bool {
        guard let index = memberIndex(for: oldToken) else { return false }
        members[index].token = newToken
        return true
    }

    @discardableResult
    func toggleFullscreen(for token: WindowToken) -> Bool {
        guard let index = memberIndex(for: token) else { return false }
        members[index].isFullscreen.toggle()
        return members[index].isFullscreen
    }

    func setFullscreen(_ fullscreen: Bool, for token: WindowToken) {
        guard let index = memberIndex(for: token) else { return }
        members[index].isFullscreen = fullscreen
    }

    @discardableResult
    func moveActive(offset: Int) -> Bool {
        let destination = activeIndex + offset
        guard members.indices.contains(destination) else { return false }
        members.swapAt(activeIndex, destination)
        activeIndex = destination
        return true
    }
}

struct StackTileSnapshot: Equatable {
    let id: StackTileId
    let members: [StackTileMember]
    let activeIndex: Int
    let tileFrame: CGRect?
    let contentFrame: CGRect?

    var activeToken: WindowToken {
        members[activeIndex].token
    }

    var isGrouped: Bool {
        members.count > 1
    }
}

enum StackWindowActivationOutcome: Equatable {
    case missing
    case selected
    case activated
}

final class StackNode {
    let id: StackNodeId
    weak var parent: StackNode?
    var children: [StackNode] = []
    var kind: StackNodeKind
    var cachedFrame: CGRect?
    var cachedContentFrame: CGRect?

    var frameAnimation: CubicRectAnimation?

    init(kind: StackNodeKind) {
        id = UUID()
        self.kind = kind
    }

    var isLeaf: Bool {
        if case .tile = kind { return true }
        return false
    }

    var windowToken: WindowToken? {
        if case let .tile(tile) = kind { return tile?.activeToken }
        return nil
    }

    var isFullscreen: Bool {
        if case let .tile(tile) = kind { return tile?.activeMember.isFullscreen == true }
        return false
    }

    var tile: StackTile? {
        if case let .tile(tile) = kind { return tile }
        return nil
    }

    func appendChild(_ child: StackNode) {
        child.detach()
        child.parent = self
        children.append(child)
    }

    func insertChild(_ child: StackNode, at index: Int) {
        child.detach()
        child.parent = self
        children.insert(child, at: min(index, children.count))
    }

    func detach() {
        parent?.children.removeAll { $0.id == self.id }
        parent = nil
    }

    func animateFrom(
        oldFrame: CGRect,
        newFrame: CGRect,
        startTime: TimeInterval,
        config: CubicConfig,
        animated: Bool
    ) {
        guard animated else {
            clearAnimations()
            return
        }

        guard Self.frameChanged(oldFrame, newFrame, tolerance: 0.5) else {
            clearAnimations()
            return
        }

        frameAnimation = CubicRectAnimation(
            animation: CubicAnimation(
                from: 0.0,
                to: 1.0,
                startTime: startTime,
                config: config
            ),
            fromFrame: oldFrame,
            toFrame: newFrame
        )
    }

    private static func frameChanged(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) > tolerance ||
            abs(lhs.origin.y - rhs.origin.y) > tolerance ||
            abs(lhs.width - rhs.width) > tolerance ||
            abs(lhs.height - rhs.height) > tolerance
    }

    func presentedFrame(at time: TimeInterval) -> CGRect? {
        frameAnimation?.currentFrame(at: time) ?? cachedContentFrame ?? cachedFrame
    }

    func tickAnimations(at time: TimeInterval) {
        if let anim = frameAnimation, anim.isComplete(at: time) {
            frameAnimation = nil
        }
    }

    func hasActiveAnimations(at time: TimeInterval) -> Bool {
        if let anim = frameAnimation, !anim.isComplete(at: time) { return true }
        return false
    }

    func clearAnimations() {
        frameAnimation = nil
    }
}

enum StackNodeKind {
    case root
    case masterArea
    case stackArea
    case tile(StackTile?)
}

final class StackWorkspaceState {
    let root = StackNode(kind: .root)
    var leafByToken: [WindowToken: StackNode] = [:]
    var tileCount = 0
    var selectedNodeId: StackNodeId?
    var pendingMovementFrameSeeds: [WindowToken: CGRect] = [:]

    var orderedNodes: [StackNode] {
        var masters: [StackNode] = []
        var stacks: [StackNode] = []
        for child in root.children {
            switch child.kind {
            case .masterArea:
                masters = child.children
            case .stackArea:
                stacks = child.children
            default:
                break
            }
        }
        return masters + stacks
    }

    var masterNodes: [StackNode] {
        guard let masterArea = root.children.first(where: {
            if case .masterArea = $0.kind { return true }
            return false
        }) else { return [] }
        return masterArea.children
    }

    var stackNodes: [StackNode] {
        guard let stackArea = root.children.first(where: {
            if case .stackArea = $0.kind { return true }
            return false
        }) else { return [] }
        return stackArea.children
    }

    func nodeIndex(_ node: StackNode) -> Int? {
        orderedNodes.firstIndex { $0.id == node.id }
    }
}
