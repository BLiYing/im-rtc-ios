#if canImport(UIKit)
import UIKit

/*
 来电横幅（规范 §06「来电横幅」）：左右各留 8、高 62、圆角 16；头像 38（渐变底 + 首字母）+ 两行字 +
 拒绝 / 接听两个 38 圆。**来电先出横幅，不直接全屏**——用户正在打字时被一整屏盖住很粗暴。
 点横幅本体展开成全屏来电页；5s 不处理由 IMCallWindow 升级为全屏。
 图标用 SF Symbols（`IMKitIcon`），不用 emoji。
 */
public final class IMIncomingBanner: UIView {

    public var onExpand: (() -> Void)?
    public var onAccept: (() -> Void)?
    public var onReject: (() -> Void)?

    private let avatarLabel = UILabel()
    private let avatarGradient = CAGradientLayer()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let acceptButton = UIButton(type: .system)
    private let rejectButton = UIButton(type: .system)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        avatarGradient.frame = avatarLabel.bounds
    }

    public func apply(caller: String, mediaType: String, isGroup: Bool) {
        avatarLabel.text = imAvatarInitial(caller)
        let (top, bottom) = IMKitTheme.avatarGradient(for: caller)
        avatarGradient.colors = [top.cgColor, bottom.cgColor]
        titleLabel.text = caller
        subtitleLabel.text = isGroup ? "邀请你加入群通话" : (mediaType == "video" ? "邀请你视频通话" : "邀请你语音通话")
        acceptButton.setImage((mediaType == "video" ? IMKitIcon.video : IMKitIcon.phone).image(pointSize: 16), for: .normal)
    }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.banner
        layer.cornerRadius = 16
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 17
        layer.shadowOffset = CGSize(width: 0, height: 14)

        avatarLabel.font = .systemFont(ofSize: 13, weight: .bold)
        avatarLabel.textColor = theme.primaryText
        avatarLabel.textAlignment = .center
        avatarLabel.backgroundColor = theme.avatarBackground
        avatarLabel.layer.cornerRadius = 19
        avatarLabel.clipsToBounds = true
        avatarGradient.startPoint = CGPoint(x: 0.15, y: 0)
        avatarGradient.endPoint = CGPoint(x: 0.85, y: 1)
        avatarLabel.layer.insertSublayer(avatarGradient, at: 0)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = theme.secondaryText

        for (button, color, tint, icon, label) in [
            (rejectButton, theme.danger, theme.primaryText, IMKitIcon.xmark, "拒绝"),
            (acceptButton, theme.accept, theme.acceptText, IMKitIcon.phone, "接听"),
        ] {
            button.backgroundColor = color
            button.tintColor = tint
            button.setImage(icon.image(pointSize: 16), for: .normal)
            button.layer.cornerRadius = 19
            button.accessibilityLabel = label
        }
        rejectButton.addTarget(self, action: #selector(reject), for: .touchUpInside)
        acceptButton.addTarget(self, action: #selector(accept), for: .touchUpInside)

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 1

        let row = UIStackView(arrangedSubviews: [avatarLabel, text, UIView(), rejectButton, acceptButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 62),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            avatarLabel.widthAnchor.constraint(equalToConstant: 38),
            avatarLabel.heightAnchor.constraint(equalToConstant: 38),
            rejectButton.widthAnchor.constraint(equalToConstant: 38),
            rejectButton.heightAnchor.constraint(equalToConstant: 38),
            acceptButton.widthAnchor.constraint(equalToConstant: 38),
            acceptButton.heightAnchor.constraint(equalToConstant: 38),
        ])

        // 点横幅本体展开全屏。按钮自己吃掉自己的触摸，不会误触发展开。
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(expand)))
        isAccessibilityElement = false
    }

    @objc private func expand() { onExpand?() }
    @objc private func accept() { onAccept?() }
    @objc private func reject() { onReject?() }
}
#endif
