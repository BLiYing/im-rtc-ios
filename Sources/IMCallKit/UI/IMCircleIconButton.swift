#if canImport(UIKit)
import UIKit

/*
 圆形图标按钮是 Kit 里到处都有的一块外观：一个 SF Symbol + 纯色底 + 圆角等于半径。
 `IMCallHeaderView` 的收起 / 加人、`IMIncomingBanner` 的接听 / 拒绝、`IMFloatingBubble`
 的挂断都是同一套属性，原先各写一遍。这里只管「看起来是什么」——尺寸约束、
 target-action、后续状态切换（如 `IMIncomingBanner` 的摄像头按钮会在 `apply` 里
 换图标）仍留在各自的调用方，三处的布局与手势本来就不一样。
 */

/// imConfigureCircleIconButton 把一颗按钮配成圆形图标按钮的外观。
/// `diameter` 决定圆角（= diameter / 2），与按钮的实际尺寸约束保持调用方自己对齐。
func imConfigureCircleIconButton(_ button: UIButton, icon: IMKitIcon, pointSize: CGFloat,
                                 diameter: CGFloat, tint: UIColor, background: UIColor,
                                 accessibilityLabel: String) {
    button.setImage(icon.image(pointSize: pointSize), for: .normal)
    button.tintColor = tint
    button.backgroundColor = background
    button.layer.cornerRadius = diameter / 2
    button.accessibilityLabel = accessibilityLabel
}
#endif
