#if canImport(UIKit)
import UIKit

/*
 通话页的圆形控制按钮（规范 §06「控制按钮的五个态」）：**圆里一个图标、圆下一行文字**。

 五个态：常态（白 14%）、开启（反白 + 换成 slash 图标）、危险（恒红、64 大）、接听（恒绿、64 大）、
 禁用（35% 不透明，**点了要出提示不能静默**——由调用方决定提示什么）。
 按下缩放 0.92 + 底色加深 120ms。与 Web 的 `ControlButton.tsx` 是同一套视觉，文案逐字对齐。

 # 图标用 SF Symbols，不用 emoji

 第一版拿 emoji 当图标（🎤 📷 🔊），实测在设备上**渲染成一个个方框问号**——
 emoji 的字形要靠字体回退，在 `UILabel` + 系统字体这条路上并不保证命中。
 SF Symbols 是系统内置的矢量图标，「开/关」两态本来就有成对的符号（`mic.fill` / `mic.slash.fill`）。
 符号名统一取自 `IMKitIcon`（与设计稿 §05 的对照表一致），不散写字符串。

 **开启态除了变色还要换图标**——不用颜色作为唯一信息载体（CONVENTIONS §8 无障碍）。
 */
public final class IMControlButton: UIControl {

    /// 按钮的角色，决定常态配色。
    public enum Role {
        case normal
        case danger   // 挂断 / 拒绝 / 取消
        case accept   // 接听
    }

    /// 尺寸：normal 56 / big 64（终止类动作）/ small 44（第二排的次级动作）。
    public enum Size {
        case normal, big, small
    }

    /// 开启态。**除了变色还要换图标**。
    public var isOn = false {
        didSet { applyStyle() }
    }

    /// 禁用态：权限被拒的摄像头、满员时的加人。**仍然可点**——调用方要借这一下出提示。
    public var isDisabledLook = false {
        didSet { applyStyle() }
    }

    /// 文案可换（「挂断」↔「离开」↔「取消」）。
    public var caption: String {
        get { offCaption }
        set { offCaption = newValue; applyStyle() }
    }

    private let role: Role
    private let size: Size
    private let circle = UIView()
    private let iconView = UIImageView()
    private let captionLabel = UILabel()
    private let offIcon: IMKitIcon
    private let onIcon: IMKitIcon
    private var offCaption: String
    private let onCaption: String

    /// - Parameters:
    ///   - icon: 关闭态的图标。
    ///   - onIcon: 开启态的图标；不给就沿用 `icon`。
    public init(role: Role = .normal, size: Size? = nil, icon: IMKitIcon, caption: String,
                onIcon: IMKitIcon? = nil, onCaption: String? = nil) {
        self.role = role
        // 危险 / 接听默认 64 大（规范 §04：只有终止类动作放大）。
        self.size = size ?? (role == .normal ? .normal : .big)
        self.offIcon = icon
        self.onIcon = onIcon ?? icon
        self.offCaption = caption
        self.onCaption = onCaption ?? caption
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    private var diameter: CGFloat {
        let theme = IMKitTheme.current
        switch size {
        case .normal: return theme.controlSize
        case .big: return theme.controlSizeBig
        case .small: return theme.controlSizeSmall
        }
    }

    private var iconPointSize: CGFloat {
        let theme = IMKitTheme.current
        switch size {
        case .normal: return theme.iconPointSize
        case .big: return theme.iconPointSizeBig
        case .small: return theme.iconPointSizeSmall
        }
    }

    private func build() {
        let theme = IMKitTheme.current
        circle.isUserInteractionEnabled = false
        circle.layer.cornerRadius = diameter / 2
        circle.clipsToBounds = true

        iconView.contentMode = .scaleAspectFit

        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textAlignment = .center
        captionLabel.textColor = theme.secondaryText
        // 文案可能比按钮宽（"关摄像头"），让它自己缩一点而不是把布局撑歪。
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.8

        for view in [circle, captionLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(iconView)

        NSLayoutConstraint.activate([
            circle.topAnchor.constraint(equalTo: topAnchor),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.widthAnchor.constraint(equalToConstant: diameter),
            circle.heightAnchor.constraint(equalToConstant: diameter),

            iconView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: circle.centerYAnchor),

            // 圆下面 7pt 是说明字（规范 §04）。
            captionLabel.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 7),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyStyle()
    }

    private func applyStyle() {
        let theme = IMKitTheme.current
        switch role {
        case .danger:
            circle.backgroundColor = theme.danger
            iconView.tintColor = theme.primaryText
        case .accept:
            circle.backgroundColor = theme.accept
            iconView.tintColor = theme.acceptText
        case .normal:
            circle.backgroundColor = isOn ? theme.controlActiveBackground : theme.controlBackground
            iconView.tintColor = isOn ? theme.controlActiveText : theme.primaryText
        }
        iconView.image = (isOn ? onIcon : offIcon).image(pointSize: iconPointSize)
        captionLabel.text = isOn ? onCaption : offCaption
        alpha = isDisabledLook ? 0.35 : 1
        accessibilityLabel = captionLabel.text
        isAccessibilityElement = true
        accessibilityTraits = isDisabledLook ? [.button, .notEnabled] : .button
    }

    /// 按下缩放 0.92 + 底色加深，松手弹回（规范 §07）。
    public override var isHighlighted: Bool {
        didSet {
            let theme = IMKitTheme.current
            UIView.animate(withDuration: theme.pressDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.circle.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
                self.circle.alpha = self.isHighlighted && !self.isDisabledLook ? 0.85 : 1
            }
        }
    }
}
#endif
