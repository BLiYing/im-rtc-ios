#if canImport(UIKit)
import UIKit

/*
 来电横幅。草图 §04：**来电先出横幅，不直接全屏**——用户正在打字时被一整屏盖住很粗暴。
 横幅停在顶部，点横幅本体展开成全屏来电页，横幅上就能直接接/拒。

 它跟全屏页共用同一个 controller，只是另一种呈现；开关在 `IMCallKitConfig.bannerFirst`。
 */
public final class IMIncomingBanner: UIView {

    public var onExpand: (() -> Void)?
    public var onAccept: (() -> Void)?
    public var onReject: (() -> Void)?

    private let avatarLabel = UILabel()
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

    public func apply(caller: String, mediaType: String) {
        avatarLabel.text = String(caller.prefix(1)).uppercased()
        titleLabel.text = caller
        subtitleLabel.text = mediaType == "video" ? "邀请你视频通话" : "邀请你语音通话"
        acceptButton.setTitle(mediaType == "video" ? "📹" : "📞", for: .normal)
    }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.overlayBackground
        layer.cornerRadius = 16
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)

        avatarLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        avatarLabel.textColor = theme.primaryText
        avatarLabel.textAlignment = .center
        avatarLabel.backgroundColor = theme.avatarBackground
        avatarLabel.layer.cornerRadius = 22
        avatarLabel.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = theme.secondaryText

        for (button, color, label) in [(rejectButton, theme.danger, "拒绝"),
                                       (acceptButton, theme.accept, "接听")] {
            button.backgroundColor = color
            button.tintColor = .white
            button.titleLabel?.font = .systemFont(ofSize: 18)
            button.layer.cornerRadius = 20
            button.accessibilityLabel = label
        }
        rejectButton.setTitle("✕", for: .normal)
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
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            avatarLabel.widthAnchor.constraint(equalToConstant: 44),
            avatarLabel.heightAnchor.constraint(equalToConstant: 44),
            rejectButton.widthAnchor.constraint(equalToConstant: 40),
            rejectButton.heightAnchor.constraint(equalToConstant: 40),
            acceptButton.widthAnchor.constraint(equalToConstant: 40),
            acceptButton.heightAnchor.constraint(equalToConstant: 40),
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
