#if canImport(UIKit)
import UIKit

/*
 一个成员格子：有画面时显示画面，没有时显示头像首字母。

 **画面只经 `engine.attachView(_:to:)` 挂载**（CONVENTIONS §1）：
 Kit 不碰 PeerConnection，也不自己拼流。换媒体实现时这个类一行不用改。
 */
public final class IMVideoTileView: UIView {
    /// 远端画面的载体。媒体层往这上面挂渲染视图。
    public let renderView = UIView()

    private let avatarLabel = UILabel()
    private let nameLabel = UILabel()
    private let mutedBadge = UILabel()
    private let stack = UIStackView()

    public private(set) var uid = ""

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.tileBackground
        layer.cornerRadius = theme.tileCornerRadius
        clipsToBounds = true
        // **拆成 longhand 而不是简写**：描边颜色会随「正在说话」变，
        // 用 border 简写再改 borderColor 在某些渲染路径下会留下不一致的边。
        layer.borderWidth = 2
        layer.borderColor = UIColor.clear.cgColor

        renderView.backgroundColor = .clear
        avatarLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        avatarLabel.textColor = theme.primaryText
        avatarLabel.textAlignment = .center
        avatarLabel.backgroundColor = theme.avatarBackground

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = theme.primaryText

        mutedBadge.text = "🔇"
        mutedBadge.font = .systemFont(ofSize: 13)
        mutedBadge.textAlignment = .center
        mutedBadge.backgroundColor = UIColor(white: 0, alpha: 0.55)
        mutedBadge.layer.cornerRadius = 12
        mutedBadge.clipsToBounds = true
        mutedBadge.isHidden = true
        // 角标是纯 emoji，读屏软件念不出「静音」。
        mutedBadge.isAccessibilityElement = true
        mutedBadge.accessibilityLabel = "已静音"

        let plate = UIView()
        plate.backgroundColor = UIColor(white: 0, alpha: 0.55)
        plate.layer.cornerRadius = 6
        plate.clipsToBounds = true

        for view in [renderView, avatarLabel, plate, mutedBadge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: topAnchor),
            renderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: bottomAnchor),

            avatarLabel.topAnchor.constraint(equalTo: topAnchor),
            avatarLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatarLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            avatarLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            // 静音角标放右上，与左下的名字牌分开：名字可能很长，
            // 挤在一起时角标会被顶出格子。
            mutedBadge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            mutedBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mutedBadge.widthAnchor.constraint(equalToConstant: 24),
            mutedBadge.heightAnchor.constraint(equalToConstant: 24),

            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: plate.topAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -2),
            nameLabel.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -8),
        ])
    }

    /// apply 按成员状态刷新格子。
    public func apply(uid: String, label: String, hasVideo: Bool, hasAudio: Bool,
                      isSpeaking: Bool) {
        self.uid = uid
        nameLabel.text = label
        avatarLabel.text = String(label.prefix(1)).uppercased()
        // 没画面时露出头像。**用 isHidden 不用改层级**：层级一动，
        // 媒体层挂在 renderView 上的渲染视图会跟着重建。
        avatarLabel.isHidden = hasVideo
        renderView.isHidden = !hasVideo
        mutedBadge.isHidden = hasAudio
        layer.borderColor = isSpeaking
            ? IMKitTheme.current.speakingBorder.cgColor
            : UIColor.clear.cgColor
    }
}
#endif
