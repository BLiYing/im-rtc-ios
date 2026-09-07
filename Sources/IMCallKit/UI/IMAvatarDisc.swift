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
    /// 宿主给的头像图。**盖在渐变与首字母之上**——有图时就不该看见色块。
    private let photo = UIImageView()

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
        // 图放在首字母之后加，层级才在它上面（同一个坑：渐变当年就是加错了顺序）。
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.isHidden = true
        photo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(photo)
        NSLayoutConstraint.activate([
            initial.centerXAnchor.constraint(equalTo: centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: centerYAnchor),
            photo.topAnchor.constraint(equalTo: topAnchor),
            photo.leadingAnchor.constraint(equalTo: leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: trailingAnchor),
            photo.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    public func apply(key: String, name: String, size: CGFloat, image: UIImage? = nil) {
        photo.image = image
        photo.isHidden = image == nil
        initial.isHidden = image != nil
        guard image == nil else { return }
        /*
         **底色按 key（uid）取，首字母按 name（显示名）取。**
         底色跟 uid 走才能五端稳定（规范 §02）——同一个人在谁的屏幕上都是同一个颜色；
         而显示名是每台设备各算各的（备注！），拿它取色会让同一个人换台设备就变个颜色。
        */
        initial.text = imAvatarInitial(name)
        initial.font = .systemFont(ofSize: (size / 3).rounded(), weight: .bold)
        let (top, bottom) = IMKitTheme.avatarGradient(for: key.isEmpty ? name : key)
        gradient.colors = [top.cgColor, bottom.cgColor]
    }
}
#endif
