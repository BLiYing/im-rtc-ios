#if canImport(UIKit)
import UIKit

/*
 来电横幅（规范 §06「来电横幅」）：左右各留 8、高 62、圆角 16；头像 38（渐变底 + 首字母）+ 两行字 +
 拒绝 / 接听两个 38 圆。**来电先出横幅，不直接全屏**——用户正在打字时被一整屏盖住很粗暴。
 点横幅本体展开成全屏来电页。**没有「5s 自动升级为全屏」**（v3.2 撤掉）：
 要么横幅要么全屏，由 `IMCallKitConfig.bannerFirst` 一个开关决定，中途自己变身
 既没必要、也让「现在到底该显示哪一个」多出一条时间维度的分支。

 视频来电多一颗**关摄像头**：接起来之前就能决定要不要出镜（Web 端一直有，两端补齐）。
 图标用 SF Symbols（`IMKitIcon`），不用 emoji。
 */
public final class IMIncomingBanner: UIView {

    public var onExpand: (() -> Void)?
    public var onAccept: (() -> Void)?
    public var onReject: (() -> Void)?
    /// 视频来电上的「关摄像头」：接起来之前先决定要不要出镜。
    public var onToggleCamera: (() -> Void)?

    private let avatarDisc = IMAvatarDiscView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let acceptButton = UIButton(type: .system)
    private let rejectButton = UIButton(type: .system)
    private let cameraButton = UIButton(type: .system)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public func apply(caller: String, mediaType: String, isGroup: Bool, cameraOn: Bool) {
        avatarDisc.apply(key: caller, name: caller, size: 38)
        titleLabel.text = caller
        subtitleLabel.text = isGroup ? "邀请你加入群通话" : (mediaType == "video" ? "邀请你视频通话" : "邀请你语音通话")
        acceptButton.setImage((mediaType == "video" ? IMKitIcon.video : IMKitIcon.phone).image(pointSize: 16), for: .normal)
        // 语音来电没有摄像头可关。
        cameraButton.isHidden = mediaType != "video"
        cameraButton.setImage((cameraOn ? IMKitIcon.video : IMKitIcon.videoSlash).image(pointSize: 16), for: .normal)
        cameraButton.accessibilityLabel = cameraOn ? "关摄像头" : "开摄像头"
    }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.banner
        layer.cornerRadius = 16
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 17
        layer.shadowOffset = CGSize(width: 0, height: 14)

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
        cameraButton.backgroundColor = theme.controlBackground
        cameraButton.tintColor = theme.primaryText
        cameraButton.layer.cornerRadius = 19
        cameraButton.addTarget(self, action: #selector(toggleCamera), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(reject), for: .touchUpInside)
        acceptButton.addTarget(self, action: #selector(accept), for: .touchUpInside)

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 1

        let row = UIStackView(arrangedSubviews: [avatarDisc, text, UIView(), cameraButton, rejectButton, acceptButton])
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
            avatarDisc.widthAnchor.constraint(equalToConstant: 38),
            avatarDisc.heightAnchor.constraint(equalToConstant: 38),
            cameraButton.widthAnchor.constraint(equalToConstant: 38),
            cameraButton.heightAnchor.constraint(equalToConstant: 38),
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
    @objc private func toggleCamera() { onToggleCamera?() }
    @objc private func accept() { onAccept?() }
    @objc private func reject() { onReject?() }
}
#endif
