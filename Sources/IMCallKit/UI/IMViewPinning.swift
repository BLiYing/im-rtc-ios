#if canImport(UIKit)
import UIKit

/*
 「四边贴满父视图」是 Kit 里最常见的约束样板：`renderView` 贴满球体、画面贴满小窗、
 头像图贴满圆盘……原先每处各写一遍四条 `NSLayoutConstraint`，`IMCallOverlayViewController`
 里甚至已经抽过一次私有 `pin(_:to:inset:)`，但只在那一个文件里能用。提成这个扩展，
 全 Kit 共用。
 */
extension UIView {
    /// imPinEdges 用四条约束把自己贴满 `parent`，`inset` 收进去多少（默认 0，四边同值）。
    ///
    /// **不动 `translatesAutoresizingMaskIntoConstraints`**——调用方在贴之前就该关掉它。
    /// 返回激活好的四条约束：多数调用方用不上，但像 `IMOverlayTiles` 那样需要在
    /// 视图换宿主时先 `deactivate` 再重新贴一遍的，留着这个返回值就够了。
    @discardableResult
    func imPinEdges(to parent: UIView, inset: CGFloat = 0) -> [NSLayoutConstraint] {
        let constraints = [
            topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }
}
#endif
