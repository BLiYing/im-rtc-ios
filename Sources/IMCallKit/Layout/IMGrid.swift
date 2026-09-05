import Foundation

/*
 九宫格布局与**层上界**的计算。

 这一段是纯算术，但它直接决定了带宽：格子越小、报的层越低、服务端发的码率越低。
 所以它值得单测，而不是散在 ViewController 的布局代码里（CONVENTIONS §2）。

 群通话上限 9 人（拍板 §11-1），正好 3×3。
 Web 端的同一层是 `packages/call-uikit-react/src/layout/grid.ts`，两边算出来必须一致。
 */

/// 一屏最多摆几个格子。超过的部分不显示（v1 不做翻页）。
public let IMMaxTiles = 9

/// 格子的行列数。
public struct IMGridDimensions: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
}

/**
 按人数与**容器的宽高比**算行列。

 # 为什么要看宽高比

 原先固定取 `ceil(sqrt(n))` 列。竖屏手机上 2 个人就成了 **1 行 2 列**：
 每格半个屏宽、整个屏高，画面被拉成两条细长条，实测反馈是「很丑」。
 同样一份人数，横屏的电脑上 2 列才是对的。**决定列数的不是人数，是容器形状。**

 # 规则：让格子尽量大，且**恒为正方形**

 逐个试列数，算出那种排法下正方形格子的边长
 `min(按列分到的宽, 按行分到的高)`，取边长最大的那个。平手时取行数少的
 （同样大的格子，摊得矮一点更接近人眼习惯的「一排排」）。

 这条规则四端共用一份（Web 的 `layout/grid.ts` 是同一个算法），
 所以同样的人数 + 同样的容器形状，各端算出来必须一样。

 - Parameters:
   - count: 格子数（含本端）。
   - aspect: 容器的 宽 / 高。竖屏手机约 0.7，横屏电脑 1.5 以上。
     默认 1（正方形容器），此时退化成老的 `ceil(sqrt(n))`。
   - gapRatio: 间距占容器短边的比例，只影响边界情况，默认 0.02。
 */
public func imGridDimensions(_ count: Int,
                             aspect: Double = 1,
                             gapRatio: Double = 0.02) -> IMGridDimensions {
    let n = min(max(count, 1), IMMaxTiles)
    // 归一化成「宽 = aspect、高 = 1」的容器；只比大小，绝对尺寸无所谓。
    let width = max(aspect, 0.01)
    let height = 1.0
    let gap = min(width, height) * gapRatio

    var best = IMGridDimensions(columns: n, rows: 1)
    var bestSide = -1.0
    for columns in 1...n {
        let rows = Int(ceil(Double(n) / Double(columns)))
        let cellWidth = (width - Double(columns - 1) * gap) / Double(columns)
        let cellHeight = (height - Double(rows - 1) * gap) / Double(rows)
        let side = min(cellWidth, cellHeight)
        // 严格大于才换：平手时保留先算出来的（列数少 = 行数多）……
        // 但我们要的是**行数少**，所以平手时取行数更少的那个。
        if side > bestSide || (side == bestSide && rows < best.rows) {
            best = IMGridDimensions(columns: columns, rows: rows)
            bestSide = side
        }
    }
    return best
}

/**
 决定每个格子该报哪一层（协议 §3.5）。

 **报的是上界不是命令**：服务端会取 min(这个上界, 带宽估计允许的层, 实际存在的层)。
 分档按格子的实际大小走——1 个人是全屏、2~4 人半屏、5 人以上就是缩略图了。

 **这是省带宽的关键一步**：九宫格里每个人都按 h 层收，一屏就是 8 路 720p。
 */
public func imTileLayer(_ tileCount: Int) -> String {
    switch tileCount {
    case ...1: return "h"
    case 2...4: return "m"
    default: return "l"
    }
}

/// 截掉超出一屏的格子。
///
/// 截断而不是缩到看不清：9 个 3×3 已经是「能看清是谁」的下限，
/// 再多就该做翻页或「只看主讲人」，那是后续期的事。
public func imVisibleTiles<T>(_ tiles: [T]) -> [T] {
    tiles.count <= IMMaxTiles ? tiles : Array(tiles.prefix(IMMaxTiles))
}

/// 把秒数格式化成 `mm:ss` / `h:mm:ss`。
public func imFormatDuration(_ seconds: Int) -> String {
    let s = max(seconds, 0)
    let hours = s / 3600, minutes = (s % 3600) / 60, secs = s % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%02d:%02d", minutes, secs)
}
