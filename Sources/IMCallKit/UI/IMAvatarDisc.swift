#if canImport(UIKit)
import UIKit

/**
 渐变头像盘：一圈渐变底 + 居中的首字母（规范 §06）。

 **为什么要单独一个视图，而不是给 UILabel 插一层 CAGradientLayer**：
 CALayer 的绘制顺序是「背景色 → 自身内容 → 子层」，UILabel 的文字画在**自身内容**里，
 所以 `label.layer.insertSublayer(gradient, at: 0)` 那个 `at: 0` 只在子层之间排序——
 渐变仍然盖在文字上面，首字母**一个都看不见**。真机上就是「头像是个纯色圆，没有字」。
 把渐变放进容器视图、文字放它上面，顺序才是对的。
 */
public final class IMAvatarDiscView: UIView {

    private let gradient = CAGradientLayer()
    private let initial = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = IMKitTheme.current.avatarBackground
        clipsToBounds = true
        gradient.startPoint = CGPoint(x: 0.15, y: 0)
        gradient.endPoint = CGPoint(x: 0.85, y: 1)
        layer.insertSublayer(gradient, at: 0)

        initial.textAlignment = .center
        initial.textColor = IMKitTheme.current.primaryText
        initial.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initial)
        NSLayoutConstraint.activate([
            initial.centerXAnchor.constraint(equalTo: centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layer.cornerRadius = bounds.width / 2
    }

    /**
     apply 刷新头像盘。

     - Parameter key: 取渐变用的键，一般是 uid（同一个人在四端同一个配色）。空串时退回用 `name`。
     - Parameter name: 显示名，取首字母用。
     - Parameter size: 直径，字号按它的 1/3 走。
     */
    public func apply(key: String, name: String, size: CGFloat) {
        initial.text = imAvatarInitial(name)
        initial.font = .systemFont(ofSize: (size / 3).rounded(), weight: .bold)
        let (top, bottom) = IMKitTheme.avatarGradient(for: key.isEmpty ? name : key)
        gradient.colors = [top.cgColor, bottom.cgColor]
    }
}
#endif
