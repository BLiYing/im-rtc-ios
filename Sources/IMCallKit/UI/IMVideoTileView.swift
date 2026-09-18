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
    /** 名牌气泡里那枚说话/静音图标（2026-09-09 改版，见 [IMSpeechIconView]）。 */
    private let speechIcon = IMSpeechIconView()
    private let netBadge = IMNetworkBars(compact: true)
    private let netPlate = UIView()

    /// 角标离格子边缘的距离。**12 而不是 8**：格子有 10 的圆角，贴到 8 名字会被切掉一截。
    private static let plateInset: CGFloat = 12

    /**
     小于这个边长的格子换一档更紧的名字牌（演讲者视图底部条是 84）。

     常规档的固定件要吃掉 12 × 2 + 8 + 5 + 9（说话图标）+ 8 = **54pt**，
     84 的格子里留给名字的只剩 30pt——连 `carol` 都放不下，每一格都是「ca…」
     （2026-09-18 真机，三端同病）。紧凑档把固定件压到 28pt。
     三端同值（Android `IMGrid.COMPACT_TILE_DP`、Web `VideoTileProps.compact`）。
     */
    private static let compactSide: CGFloat = 110

    /// 紧凑档的留白。圆角在小格子上也小，4 不会被切。
    private static let compactInset: CGFloat = 4

    /// 随档位变的那几条约束与当前档位（`nil` = 还没定过，第一次必设）。
    private var densityConstraints: [NSLayoutConstraint] = []
    private var isCompact: Bool?
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

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.tileBackground
        layer.cornerRadius = theme.tileCornerRadius
        clipsToBounds = true

        renderView.backgroundColor = .clear

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = theme.primaryText
        // 格子小到放不下整个名字时**截断**，而不是把自己压成零宽。
        // 说话图标是恒宽的硬约束，名字牌又是内容撑出来的：两边都不肯让，
        // 名字就会被挤成一条缝（见 namePlate 的宽度上限）。
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        namePlate.backgroundColor = theme.scrim
        namePlate.layer.cornerRadius = 6
        namePlate.clipsToBounds = true

        netPlate.backgroundColor = theme.scrim
        netPlate.layer.cornerRadius = 12
        netPlate.isHidden = true
        netPlate.isAccessibilityElement = true
        netPlate.accessibilityLabel = "网络不佳"

        ringingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ringingLabel.textColor = theme.primaryText
        ringingLabel.textAlignment = .center
        ringingLabel.isHidden = true

        for view in [renderView, avatarDisc, namePlate, netPlate, ringingLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for (child, plate) in [(nameLabel, namePlate), (speechIcon, namePlate), (netBadge, netPlate)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(child)
        }

        avatarSizeConstraints = [
            avatarDisc.widthAnchor.constraint(equalToConstant: 44),
            avatarDisc.heightAnchor.constraint(equalToConstant: 44),
        ]
        // 这几条随「格子多大」换档（见 applyDensity），所以要留着引用。
        let netTop = netPlate.topAnchor.constraint(equalTo: topAnchor, constant: Self.plateInset)
        let netTrailing = netPlate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.plateInset)
        let plateLeading = namePlate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.plateInset)
        let plateBottom = namePlate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.plateInset)
        let plateHeight = namePlate.heightAnchor.constraint(equalToConstant: 20)
        let labelLeading = nameLabel.leadingAnchor.constraint(equalTo: namePlate.leadingAnchor, constant: 8)
        let iconLeading = speechIcon.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 5)
        let iconTrailing = speechIcon.trailingAnchor.constraint(equalTo: namePlate.trailingAnchor, constant: -8)
        densityConstraints = [netTop, netTrailing, plateLeading, plateBottom, plateHeight,
                              labelLeading, iconLeading, iconTrailing]
        renderView.imPinEdges(to: self)
        NSLayoutConstraint.activate(avatarSizeConstraints + [
            avatarDisc.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatarDisc.centerYAnchor.constraint(equalTo: centerYAnchor),

            netTop, netTrailing,
            netPlate.widthAnchor.constraint(equalToConstant: 24),
            netPlate.heightAnchor.constraint(equalToConstant: 24),
            netBadge.centerXAnchor.constraint(equalTo: netPlate.centerXAnchor),
            netBadge.centerYAnchor.constraint(equalTo: netPlate.centerYAnchor),

            // 离左边与下边都留 12（比原来的 8 大）：格子有圆角，贴到 8 的话名字会被切掉一截。
            plateLeading, plateBottom, plateHeight,
            /*
             宽度上限只留一个边距。

             原先留的是 40：84pt 的格子（演讲者视图底部条）里名字牌只剩 32pt，
             而牌子里恒定要吃掉 8 + 5 + 9（说话图标）+ 8 = 30pt——**留给名字的正好 2pt，
             一个字都看不见**（2026-09-18 真机）。大格子上看不出来，只有小格子会中。
            */
            namePlate.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                constant: -Self.plateInset),
            nameLabel.centerYAnchor.constraint(equalTo: namePlate.centerYAnchor),
            labelLeading,
            // 图标**永远占位**（拍板：留位），名字不会随说话左右跳。
            iconLeading, iconTrailing,
            speechIcon.centerYAnchor.constraint(equalTo: namePlate.centerYAnchor),
            speechIcon.widthAnchor.constraint(equalToConstant: IMSpeechIconView.iconSize.width),
            speechIcon.heightAnchor.constraint(equalToConstant: IMSpeechIconView.iconSize.height),

            ringingLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            ringingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            ringingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    /**
     小格子换一档更紧的名字牌。**按自己的边长判**，不用调用方告诉：
     格子是按 uid 复用的，同一个对象一会儿在画廊（大）一会儿在底部条（小）。

     **只动留白与字号，不动结构**：说话图标照旧永远占位。
     */
    public override func layoutSubviews() {
        super.layoutSubviews()
        let wantCompact = bounds.width > 0 && bounds.width < Self.compactSide
        guard isCompact != wantCompact else { return }
        isCompact = wantCompact
        let inset = wantCompact ? Self.compactInset : Self.plateInset
        let pad: CGFloat = wantCompact ? 4 : 8
        let gap: CGFloat = wantCompact ? 3 : 5
        // 顺序与 densityConstraints 的组装一致。
        let constants: [CGFloat] = [inset, -inset, inset, -inset,
                                    wantCompact ? 16 : 20, pad, gap, -pad]
        for (constraint, value) in zip(densityConstraints, constants) { constraint.constant = value }
        nameLabel.font = .systemFont(ofSize: wantCompact ? 10 : 12)
        namePlate.layer.cornerRadius = wantCompact ? 5 : 6
    }

    /// apply 按成员状态刷新格子。
    /// - Parameter avatarSize: 头像盘直径，默认 44；1v1 全屏那一格给 96。
    /// - Parameter isMirrored: 本端预览水平镜像（人照镜子的习惯）；远端不镜像。
    public func apply(uid: String, label: String, hasVideo: Bool, hasAudio: Bool, isSpeaking: Bool, volume: Int = 0,
                      showsSpeaking: Bool = true,
                      isRinging: Bool = false, settled: IMSettledOutcome = .none, networkLevel: Int = 0,
                      avatarSize: CGFloat = 44, isMirrored: Bool = false,
                      avatarImage: UIImage? = nil) {
        self.uid = uid
        nameLabel.text = label
        // key 用 uid、name 用已解析的显示名：底色跟 uid 走才能五端稳定，
        // 而显示名各机各算（备注），拿它取色会让同一个人换台设备就变色。
        avatarDisc.apply(key: uid, name: label, size: avatarSize, image: avatarImage)
        avatarSizeConstraints.forEach { $0.constant = avatarSize }
        // 没画面时露出头像。**用 isHidden 不用改层级**：层级一动，媒体层挂在 renderView 上的渲染视图会跟着重建。
        avatarDisc.isHidden = hasVideo
        renderView.isHidden = !hasVideo
        renderView.transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        netPlate.isHidden = !imIsNetworkPoor(level: networkLevel)
        netBadge.apply(level: networkLevel)
        /*
         说话 / 静音都收进名牌气泡里那一枚图标（2026-09-09 改版）。
         **静音优先**：静音的人不可能在说话，两者互斥。
         绿描边与绿名牌一并删掉——留着就是三处同时表达同一件事。
        */
        speechIcon.apply(speaking: isSpeaking, muted: !hasAudio, volume: volume,
                         showsSpeaking: showsSpeaking)
        // **必须自己声明成无障碍元素**：namePlate 是个普通 UIView，
        // 只设 accessibilityLabel 的话读屏软件根本不会念它，会掉进里头的 nameLabel
        // 只读出名字——静音与说话就此静默消失（原先的 mutedPlate 是有这一行的）。
        namePlate.isAccessibilityElement = true
        namePlate.accessibilityLabel = !hasAudio ? "\(label)，已静音"
            : (isSpeaking && showsSpeaking) ? "\(label)，正在说话" : "\(label)，麦克风已开启"
        // 邀请中的占位格：整格 55% 不透明 + 顶部一行终局（规范 §06）。
        alpha = isRinging ? 0.55 : 1
        ringingLabel.isHidden = !isRinging
        ringingLabel.text = settled == .none ? "呼叫中…" : imSettledText(settled)
    }
}
#endif
