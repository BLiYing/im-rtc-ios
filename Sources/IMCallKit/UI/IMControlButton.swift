#if canImport(UIKit)
import UIKit

/*
 通话页的圆形控制按钮。草图 §03：**统一 56pt 圆形半透明，开启态白底黑字**，
 挂断恒红、接听恒绿。

 # 图标用 SF Symbols，不用 emoji

 第一版拿 emoji 当图标（🎤 📷 🔊），实测在设备上**渲染成一个个方框问号**——
 emoji 的字形要靠字体回退，在 `UILabel` + 系统字体这条路上并不保证命中。
 SF Symbols 是系统内置的矢量图标：字重跟着字体走、深浅色自动适配、
 支持动态字体与无障碍，而且「开/关」两态本来就有成对的符号（`mic.fill` / `mic.slash.fill`）。

 单独成类是因为「开启态」这件事出现在四个按钮上（静音、摄像头、扬声器、小窗），
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
    private let circle = UIView()
    private let iconView = UIImageView()
    private let captionLabel = UILabel()
    private let offSymbol: String
    private let onSymbol: String
    private let offCaption: String
    private let onCaption: String

    /// - Parameters:
    ///   - symbol: SF Symbol 名，如 `mic.fill`。
    ///   - onSymbol: 开启态的符号；不给就沿用 `symbol`。
    public init(role: Role = .normal, symbol: String, caption: String,
                onSymbol: String? = nil, onCaption: String? = nil) {
        self.role = role
        self.offSymbol = symbol
        self.onSymbol = onSymbol ?? symbol
        self.offCaption = caption
        self.onCaption = onCaption ?? caption
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    private func build() {
        let theme = IMKitTheme.current
        circle.isUserInteractionEnabled = false
        circle.layer.cornerRadius = theme.controlSize / 2
        circle.clipsToBounds = true

        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 22, weight: .medium)

        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textAlignment = .center
        captionLabel.textColor = theme.secondaryText
        // 文案可能比按钮宽（"以语音接听"），让它自己缩一点而不是把布局撑歪。
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
            circle.widthAnchor.constraint(equalToConstant: theme.controlSize),
            circle.heightAnchor.constraint(equalToConstant: theme.controlSize),

            iconView.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            captionLabel.topAnchor.constraint(equalTo: circle.bottomAnchor, constant: 6),
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
            iconView.tintColor = .white
        case .accept:
            circle.backgroundColor = theme.accept
            iconView.tintColor = .white
        case .normal:
            circle.backgroundColor = isOn ? theme.controlActiveBackground : theme.controlBackground
            iconView.tintColor = isOn ? theme.controlActiveText : theme.primaryText
        }
        iconView.image = UIImage(systemName: isOn ? onSymbol : offSymbol)
        captionLabel.text = isOn ? onCaption : offCaption
        accessibilityLabel = captionLabel.text
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    public override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
#endif
