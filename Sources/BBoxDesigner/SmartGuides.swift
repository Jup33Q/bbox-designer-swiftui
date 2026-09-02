import Foundation
import AppKit

// MARK: - 智能对齐吸附(纯函数核心,可单测)

/// 候选/命中的对齐参考线(画布坐标)
struct SnapLine: Equatable, Hashable {
    enum Axis: Equatable, Hashable { case h, v }
    var axis: Axis
    var pos: Double
}

/// 吸附结果:delta 用于修正拖动位置,lines 用于绘制参考线
struct SnapResult: Equatable {
    var deltaX: Double = 0
    var deltaY: Double = 0
    var lines: [SnapLine] = []
}

enum SmartGuides {
    /// 画布坐标阈值(约等于屏幕 4-5pt)
    static let threshold = 6.0

    /// 画布候选线:左/中X/右、上/中Y/下
    static func canvasCandidates(w: Double, h: Double) -> [SnapLine] {
        [SnapLine(axis: .v, pos: 0), SnapLine(axis: .v, pos: w / 2), SnapLine(axis: .v, pos: w),
         SnapLine(axis: .h, pos: 0), SnapLine(axis: .h, pos: h / 2), SnapLine(axis: .h, pos: h)]
    }

    /// 单个物体候选线:左/中X/右、上/中Y/下
    static func boxCandidates(_ b: BBox) -> [SnapLine] {
        [SnapLine(axis: .v, pos: b.x), SnapLine(axis: .v, pos: b.x + b.w / 2), SnapLine(axis: .v, pos: b.x + b.w),
         SnapLine(axis: .h, pos: b.y), SnapLine(axis: .h, pos: b.y + b.h / 2), SnapLine(axis: .h, pos: b.y + b.h)]
    }

    /// 移动吸附:rect 为拖动集合包围盒(未吸附前),6 条边线与候选线同轴匹配,各轴取 |delta| 最小者
    static func computeSnap(moving rect: CGRect, candidates: [SnapLine], threshold: Double) -> SnapResult {
        let vEdges = [rect.minX, rect.midX, rect.maxX]
        let hEdges = [rect.minY, rect.midY, rect.maxY]
        var result = SnapResult()
        var bestV: (delta: Double, line: SnapLine)? = nil
        for c in candidates where c.axis == .v {
            for e in vEdges {
                let d = c.pos - e
                if abs(d) <= threshold, bestV == nil || abs(d) < abs(bestV!.delta) { bestV = (d, c) }
            }
        }
        var bestH: (delta: Double, line: SnapLine)? = nil
        for c in candidates where c.axis == .h {
            for e in hEdges {
                let d = c.pos - e
                if abs(d) <= threshold, bestH == nil || abs(d) < abs(bestH!.delta) { bestH = (d, c) }
            }
        }
        if let b = bestV { result.deltaX = b.delta; result.lines.append(b.line) }
        if let b = bestH { result.deltaY = b.delta; result.lines.append(b.line) }
        return result
    }

    /// 缩放吸附:只对正在拖动的边(单线)做匹配(n/s 配水平线,e/w 配垂直线)
    static func computeSnap(edge pos: Double, axis: SnapLine.Axis, candidates: [SnapLine], threshold: Double) -> SnapResult {
        var best: (delta: Double, line: SnapLine)? = nil
        for c in candidates where c.axis == axis {
            let d = c.pos - pos
            if abs(d) <= threshold, best == nil || abs(d) < abs(best!.delta) { best = (d, c) }
        }
        var result = SnapResult()
        if let b = best {
            if axis == .v { result.deltaX = b.delta } else { result.deltaY = b.delta }
            result.lines = [b.line]
        }
        return result
    }
}

// MARK: - 触摸板触觉反馈

enum Haptics {
    private static var lastFiredAt: TimeInterval = 0
    /// 对齐触觉反馈;60ms 节流,防止 delta 抖动时连发。无 Force Touch 触摸板时静默跳过。
    static func alignment() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFiredAt > 0.06 else { return }
        lastFiredAt = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
}
