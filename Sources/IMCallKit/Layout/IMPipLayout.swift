import Foundation

/*
 小窗（PiP）的位置算术：四角吸附、控制条避让、按容器形状选尺寸（交互稿 §04）。

 纯函数，不碰 UIKit，与 Web 的 `layout/pip.ts` 是同一份算法——同样的容器、同样的松手点，
 两端必须吸到同一个角。手势那一层在 `UI/IMPipView.swift`，它只负责把触点坐标喂进来。
 */

/// 小窗能停的四个角。
public enum IMPipCorner: String, CaseIterable, Sendable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    /// 默认停右上角：本端画面惯例在这里（FaceTime / 微信同做法）。
    public static let `default`: IMPipCorner = .topRight

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
}

/// 小窗的宽高。
public struct IMPipSize: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// 容器坐标系里的一个点（左上角为原点）。
public struct IMPipPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 小窗离容器边缘的距离（规范 §04：安全区之内再留 12）。
public let IMPipInset = 12.0
/// 控制条显示时，停在下面两个角的小窗要上移这么多（规范 §04）。
public let IMPipLift = 88.0
/// 竖屏容器里的小窗 3:4（规范 §04）。
public let IMPipSizePortrait = IMPipSize(width: 96, height: 128)
/// 横屏容器里的小窗 16:9（iPad 横屏、桌面）。
public let IMPipSizeLandscape = IMPipSize(width: 160, height: 90)

/// imPipSize 按**容器形状**选尺寸。判据是容器不是设备：iPad 分屏成窄条也该按竖屏那套走。
public func imPipSize(containerWidth: Double, containerHeight: Double) -> IMPipSize {
    guard containerHeight > 0 else { return IMPipSizeLandscape }
    return containerWidth / containerHeight < 1 ? IMPipSizePortrait : IMPipSizeLandscape
}

/// imNearestCorner 找离某个点最近的角。松手时调它：**吸附到最近的角，不是最近的边**。
public func imNearestCorner(_ point: IMPipPoint, containerWidth: Double,
                            containerHeight: Double) -> IMPipCorner {
    let right = point.x > containerWidth / 2
    let bottom = point.y > containerHeight / 2
    if right { return bottom ? .bottomRight : .topRight }
    return bottom ? .bottomLeft : .topLeft
}

/// imPipOrigin 算某个角的小窗左上角。`lift` 是控制条显示时下面两个角的上移量。
public func imPipOrigin(_ corner: IMPipCorner, size: IMPipSize, containerWidth: Double,
                        containerHeight: Double, lift: Double = 0) -> IMPipPoint {
    let x = corner.isRight ? containerWidth - size.width - IMPipInset : IMPipInset
    let y = corner.isBottom ? containerHeight - size.height - IMPipInset - lift : IMPipInset
    return IMPipPoint(x: max(x, 0), y: max(y, 0))
}

/// imClampPipOrigin 把拖动中的左上角夹在容器里，不让小窗被拖出边界。
public func imClampPipOrigin(_ origin: IMPipPoint, size: IMPipSize, containerWidth: Double,
                             containerHeight: Double) -> IMPipPoint {
    let maxX = max(containerWidth - size.width, 0)
    let maxY = max(containerHeight - size.height, 0)
    return IMPipPoint(x: min(max(origin.x, 0), maxX), y: min(max(origin.y, 0), maxY))
}
