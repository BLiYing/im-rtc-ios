#if canImport(UIKit)
import UIKit

/*
 通话页的圆形控制按钮。草图 §03：**统一 56pt 圆形半透明，开启态白底黑字**，
 挂断恒红、接听恒绿。

 单独成类是因为「开启态」这件事出现在四个按钮上（静音、扬声器、摄像头、悬浮窗），
 写在每个 VC 里就得维护四遍。
 */
public final class IMControlButton: UIControl {
    /// 按钮的角色，决定常态配色。
    public enum Role {
        case normal
        case danger   // 挂断
        case accept   // 接听
    }

    /// 开启态。**除了变色还要换图标**——不用颜色作为唯一信息载体（CONVENTIONS §8 无障碍）。
    public var isOn = false {
        didSet { applyStyle() }
    }

    private let role: Role
    private let iconLabel = UILabel()
    private let captionLabel = UILabel()
    /// 开/关两套图标与文案。
    private let onIcon: String
    private let offIcon: String
    private let onCaption: String
    private let offCaption: String

    public init(role: Role = .normal, icon: String, caption: String,
                onIcon: String? = nil, onCaption: String? = nil) {
        self.role = role
        self.offIcon = icon
        self.onIcon = onIcon ?? icon
        self.offCaption = caption
        self.onCaption = onCaption ?? caption
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public override var intrinsicContentSize: CGSize {
        let size = IMKitTheme.current.controlSize
        return CGSize(width: size, height: size + 20) // +20 给下方文案
    }

    private func build() {
        let theme = IMKitTheme.current
        iconLabel.font = .systemFont(ofSize: 22)
        iconLabel.textAlignment = .center
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textAlignment = .center
        captionLabel.textColor = theme.secondaryText

        let circle = UIView()
        circle.isUserInteractionEnabled = false
        circle.layer.cornerRadius = theme.controlSize / 2
        circle.clipsToBounds = true
        circle.tag = 1 // applyStyle 靠它找回来

        for view in [circle, iconLabel, captionLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        circle.addSubview(iconLabel)

        NSLayoutConstraint.activate([
            circle.topAnchor.constraint(equalTo: topAnchor),
            circle.centerXAnchor.constraint(equalTo: centerXAnchor),
            circle.widthAnchor.constraint(equalToConstant: theme.controlSize),
            circle.heightAnchor.constraint(equalToConstant: theme.controlSize),
            iconLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            captionLabel.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 4),
            captionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        applyStyle()
    }

    private func applyStyle() {
        let theme = IMKitTheme.current
        let circle = subviews.first { $0.tag == 1 }
        switch role {
        case .danger:
            circle?.backgroundColor = theme.danger
            iconLabel.textColor = .white
        case .accept:
            circle?.backgroundColor = theme.accept
            iconLabel.textColor = .white
        case .normal:
            circle?.backgroundColor = isOn ? theme.controlActiveBackground : theme.controlBackground
            iconLabel.textColor = isOn ? theme.controlActiveText : theme.primaryText
        }
        iconLabel.text = isOn ? onIcon : offIcon
        captionLabel.text = isOn ? onCaption : offCaption
        // 无障碍：图标是 emoji，读屏软件念不出来，必须给 label。
        accessibilityLabel = captionLabel.text
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    public override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
#endif
