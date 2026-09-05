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
 按人数算行列。

 取「尽量接近正方形」而不是固定 3 列：4 个人排成 2×2 每格都比 3×2 大得多，
 而 3 个人排 2×2（留一个空位）比 3×1 那种细长条好看。
 */
public func imGridDimensions(_ count: Int) -> IMGridDimensions {
    let n = min(max(count, 1), IMMaxTiles)
    let columns = Int(ceil(Double(n).squareRoot()))
    return IMGridDimensions(columns: columns, rows: Int(ceil(Double(n) / Double(columns))))
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
