import Foundation

/*
 九宫格布局与**层上界**的计算。

 这一段是纯算术，但它直接决定了带宽：格子越小、报的层越低、服务端发的码率越低。
 所以它值得单测，而不是散在 ViewController 的布局代码里（CONVENTIONS §2）。

 群通话上限 9 人（拍板 §11-1），正好 3×3。
 Web 端的同一层是 `packages/call-uikit-react/src/layout/grid.ts`，
 Android 是 `IMGrid.kt`，三边算出来必须一致。
 */

/// 一屏最多摆几个格子。超过的部分不显示（v1 不做翻页）。
public let IMMaxTiles = 9

/**
 远端最多摆几个格子。

 **本端恒占一格**（九宫格里自己也是一格），所以远端只剩 8 个位置。
 原先按 `IMMaxTiles` 截远端，会议房（服务端 `UnlimitedParticipants`，不设人数上限）
 进到第 10 个人时算出来是「9 个远端 + 自己 = 10 格」，而行列只有 9 个坑：
 iOS 悄悄丢掉多的、Web 的 CSS grid 多开一行溢出居中块、Android 的 GridLayout
 越过 `rowCount` —— **同一个房间三端长得不一样**。
 */
public let IMMaxRemoteTiles = IMMaxTiles - 1

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

 # 3~4 格在竖屏容器里恒为两列

 这一条是**产品决定，不是尺寸最优解**，所以写成一句直白的规则而不是靠权重去凑：
 竖屏手机上 3 个人排成一竖条，格子其实比 2×2 还大一点（0.325 vs 0.294），
 但没人管那叫「九宫格」——交互稿 §05 画的就是「第一行两个」。

 而按「格子最大」去挑的话，翻转恰好压在手机的常见比例上（3 格 `aspect ≈ 0.662`、
 4 格 `≈ 0.495`）：iPhone 15 Pro 的舞台区算出来 0.682（2×2）、16 Pro Max 算出来
 0.648（一竖条），**同一通电话在两台手机上是两种版式**，而差的那点边长（2%）根本看不出来。
 与其把容差调到刚好盖住今天这几台设备，不如把这条规则说清楚。

 横屏（`aspect >= 1`）不受这条约束：宽容器上 3 个人一行排开本来就更好。

 # 其余人数：让格子尽量大，且**恒为正方形**

 逐个试列数，算出那种排法下正方形格子的边长
 `min(按列分到的宽, 按行分到的高)`，取边长最大的那个。平手时取行数少的
 （同样大的格子，摊得矮一点更接近人眼习惯的「一排排」）。

 这条规则四端共用一份（Web 的 `layout/grid.ts`、Android 的 `IMGrid.dimensions`
 是同一个算法），所以同样的人数 + 同样的容器形状，各端算出来必须一样。

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

    // 竖屏容器下 3~4 格恒为两列（见上）。
    if width < height, n == 3 || n == 4 {
        return IMGridDimensions(columns: 2, rows: (n + 1) / 2)
    }

    var best = IMGridDimensions(columns: n, rows: 1)
    var bestSide = -1.0
    for columns in 1...n {
        let rows = Int(ceil(Double(n) / Double(columns)))
        let cellWidth = (width - Double(columns - 1) * gap) / Double(columns)
        let cellHeight = (height - Double(rows - 1) * gap) / Double(rows)
        let side = min(cellWidth, cellHeight)
        // 严格大于才换；平手时取**行数更少**的那个。
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

/// 截掉超出一屏的**远端**格子（本端那一格由界面自己加，见 `IMMaxRemoteTiles`）。
///
/// 截断而不是缩到看不清：9 个 3×3 已经是「能看清是谁」的下限，
/// 再多就该做翻页或「只看主讲人」，那是后续期的事。
public func imVisibleTiles<T>(_ tiles: [T]) -> [T] {
    tiles.count <= IMMaxRemoteTiles ? tiles : Array(tiles.prefix(IMMaxRemoteTiles))
}

/// 把秒数格式化成 `mm:ss` / `h:mm:ss`。
public func imFormatDuration(_ seconds: Int) -> String {
    let s = max(seconds, 0)
    let hours = s / 3600, minutes = (s % 3600) / 60, secs = s % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%02d:%02d", minutes, secs)
}
