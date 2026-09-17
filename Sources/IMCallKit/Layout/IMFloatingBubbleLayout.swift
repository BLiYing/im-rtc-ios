import Foundation

/*
 悬浮球贴边计算：拖拽松手后吸附到最近的左右边缘，竖直方向夹在安全区内
 （交互稿 §03）。纯函数，不碰 UIKit——写法照抄 `IMPipLayout.swift`：只用 `Double`
 与已有的 `IMPipPoint` / `IMPipSize`，macOS 也编得过，`Tests/IMCallKitTests`
 直接单测，不用模拟器。手势与动画留在 `UI/IMFloatingBubble.swift`，这里只算目标点。
 */

/// 悬浮球离左右边缘的距离（规范 §03）。
let IMFloatingBubbleEdgeInset = 8.0
/// 悬浮球离上下边缘的距离，避开状态栏与手势条（规范 §03）。
let IMFloatingBubbleVerticalInset = 60.0

/// imFloatingBubbleSnapCenter 算悬浮球松手后的目标中心点：
/// 吸附到离当前中心点更近的那条左右边缘，竖直方向夹在
/// `[verticalInset, containerHeight - verticalInset]` 内。
///
/// `center` 是松手那一刻的中心点、`bubbleSize` 是悬浮球容器（含挂断按钮）的宽高，
/// 都用容器自己的坐标系——与 `UI/IMFloatingBubble.swift` 的 `snapToEdge(in:)`
/// 原先内联的算法逐字一致，只是搬到这里成了纯函数。
func imFloatingBubbleSnapCenter(_ center: IMPipPoint, containerWidth: Double, containerHeight: Double,
                                bubbleSize: IMPipSize,
                                edgeInset: Double = IMFloatingBubbleEdgeInset,
                                verticalInset: Double = IMFloatingBubbleVerticalInset) -> IMPipPoint {
    let half = containerWidth / 2
    let inset = containerWidth * 0.5 - edgeInset - bubbleSize.width / 2
    let targetX = center.x < half ? half - inset : half + inset
    let minY = bubbleSize.height / 2 + verticalInset
    let maxY = containerHeight - bubbleSize.height / 2 - verticalInset
    let targetY = min(max(center.y, minY), maxY)
    return IMPipPoint(x: targetX, y: targetY)
}
