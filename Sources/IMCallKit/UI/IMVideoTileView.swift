#if canImport(UIKit)
import UIKit

/*
 一个成员格子（规范 §06「格子」）：有画面时显示画面，没有时显示**渐变底 + 首字母**的头像盘。
 左下名字标签（正在说话时底变绿）、右上静音角标（`mic.slash.fill`，#FFB4AE）、右下网络角标，
 邀请中的格子整格 55% 不透明 + 顶部一行「呼叫中… / 已拒绝 / 未接听」。

 **画面只经 `engine.attachView(_:to:)` 挂载**（CONVENTIONS §1）：Kit 不碰 PeerConnection。
 */
public final class IMVideoTileView: UIView {
    /// 远端画面的载体。媒体层往这上面挂渲染视图。
    public let renderView = UIView()

    private let avatarDisc = IMAvatarDiscView()
    private let nameLabel = UILabel()
    private let namePlate = UIView()
    private let mutedBadge = UIImageView()
    private let mutedPlate = UIView()
    private let netBadge = IMNetworkBars(compact: true)
    private let netPlate = UIView()
    private let ringingLabel = UILabel()
    private var avatarSizeConstraints: [NSLayoutConstraint] = []

    public private(set) var uid = ""

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        // 格子跟着网格走，不用自己的固有尺寸去撑布局。
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public override func layoutSubviews() {
        super.layoutSubviews()
    }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.tileBackground
        layer.cornerRadius = theme.tileCornerRadius
        clipsToBounds = true
        // 发言描边是**内描边**（规范 §06：2.5 内缩，不撑大格子）。
        layer.borderWidth = theme.speakingOutline
        layer.borderColor = UIColor.clear.cgColor

        renderView.backgroundColor = .clear

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = theme.primaryText
        namePlate.backgroundColor = theme.scrim
        namePlate.layer.cornerRadius = 6
        namePlate.clipsToBounds = true

        mutedPlate.backgroundColor = theme.scrim
        mutedPlate.layer.cornerRadius = 12
        mutedPlate.isHidden = true
        mutedBadge.image = IMKitIcon.micSlash.image(pointSize: 11)
        mutedBadge.tintColor = theme.mutedBadge
        mutedBadge.contentMode = .center
        // 角标是纯图形，读屏软件念不出「静音」。
        mutedPlate.isAccessibilityElement = true
        mutedPlate.accessibilityLabel = "已静音"

        netPlate.backgroundColor = theme.scrim
        netPlate.layer.cornerRadius = 12
        netPlate.isHidden = true
        netPlate.isAccessibilityElement = true
        netPlate.accessibilityLabel = "网络不佳"

        ringingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ringingLabel.textColor = theme.primaryText
        ringingLabel.textAlignment = .center
        ringingLabel.isHidden = true

        for view in [renderView, avatarDisc, namePlate, mutedPlate, netPlate, ringingLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for (child, plate) in [(nameLabel, namePlate), (mutedBadge, mutedPlate), (netBadge, netPlate)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(child)
        }

        avatarSizeConstraints = [
            avatarDisc.widthAnchor.constraint(equalToConstant: 44),
            avatarDisc.heightAnchor.constraint(equalToConstant: 44),
        ]
        NSLayoutConstraint.activate(avatarSizeConstraints + [
            renderView.topAnchor.constraint(equalTo: topAnchor),
            renderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: bottomAnchor),

            avatarDisc.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatarDisc.centerYAnchor.constraint(equalTo: centerYAnchor),

            // 静音角标放右上，与左下的名字牌分开：名字可能很长，挤在一起时角标会被顶出格子。
            mutedPlate.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            mutedPlate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mutedPlate.widthAnchor.constraint(equalToConstant: 24),
            mutedPlate.heightAnchor.constraint(equalToConstant: 24),
            mutedBadge.centerXAnchor.constraint(equalTo: mutedPlate.centerXAnchor),
            mutedBadge.centerYAnchor.constraint(equalTo: mutedPlate.centerYAnchor),

            netPlate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            netPlate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            netPlate.widthAnchor.constraint(equalToConstant: 24),
            netPlate.heightAnchor.constraint(equalToConstant: 24),
            netBadge.centerXAnchor.constraint(equalTo: netPlate.centerXAnchor),
            netBadge.centerYAnchor.constraint(equalTo: netPlate.centerYAnchor),

            namePlate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            namePlate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            namePlate.heightAnchor.constraint(equalToConstant: 18),
            namePlate.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: namePlate.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: namePlate.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: namePlate.trailingAnchor, constant: -8),

            ringingLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            ringingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            ringingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    /// apply 按成员状态刷新格子。
    /// - Parameter avatarSize: 头像盘直径，默认 44；1v1 全屏那一格给 96。
    /// - Parameter isMirrored: 本端预览水平镜像（人照镜子的习惯）；远端不镜像。
    public func apply(uid: String, label: String, hasVideo: Bool, hasAudio: Bool, isSpeaking: Bool,
                      isRinging: Bool = false, settled: IMSettledOutcome = .none, networkLevel: Int = 0,
                      avatarSize: CGFloat = 44, isMirrored: Bool = false) {
        let theme = IMKitTheme.current
        self.uid = uid
        nameLabel.text = label
        avatarDisc.apply(key: uid, name: label, size: avatarSize)
        avatarSizeConstraints.forEach { $0.constant = avatarSize }
        // 没画面时露出头像。**用 isHidden 不用改层级**：层级一动，媒体层挂在 renderView 上的渲染视图会跟着重建。
        avatarDisc.isHidden = hasVideo
        renderView.isHidden = !hasVideo
        renderView.transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        mutedPlate.isHidden = hasAudio
        netPlate.isHidden = !imIsNetworkPoor(level: networkLevel)
        netBadge.apply(level: networkLevel)
        layer.borderColor = isSpeaking ? theme.speakingBorder.cgColor : UIColor.clear.cgColor
        // 正在说话：名字标签底变绿、字变深（规范 §06）。
        namePlate.backgroundColor = isSpeaking ? theme.accept : theme.scrim
        nameLabel.textColor = isSpeaking ? theme.acceptText : theme.primaryText
        nameLabel.font = .systemFont(ofSize: 12, weight: isSpeaking ? .semibold : .regular)
        // 邀请中的占位格：整格 55% 不透明 + 顶部一行终局（规范 §06）。
        alpha = isRinging ? 0.55 : 1
        ringingLabel.isHidden = !isRinging
        ringingLabel.text = settled == .none ? "呼叫中…" : imSettledText(settled)
    }
}
#endif
