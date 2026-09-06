#if canImport(UIKit)
import UIKit

/*
 通话页的「壳」：顶部那条、顶部橙条、提示卡。三个小视图放一个文件——它们都不含业务逻辑，
 各自单独成文件只会让 UI/ 目录变成一堆 40 行的碎片。
 */

/// 顶部那条（规范 §04）：左 32 圆「收起」、中间标题 + 副标题 + 网络条、右 32 圆「加人」。固定高 64。
public final class IMCallHeaderView: UIView {
    public let minimizeButton = UIButton(type: .system)
    public let inviteButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let networkBars = IMNetworkBars(compact: true)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public func apply(title: String, subtitle: String, networkLevel: Int, showsMinimize: Bool, showsInvite: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        networkBars.apply(level: networkLevel)
        minimizeButton.isHidden = !showsMinimize
        inviteButton.isHidden = !showsInvite
    }

    private func build() {
        let theme = IMKitTheme.current
        for (button, icon, label) in [(minimizeButton, IMKitIcon.chevronDown, "收进小窗"),
                                      (inviteButton, IMKitIcon.personAdd, "添加成员")] {
            button.setImage(icon.image(pointSize: 15), for: .normal)
            button.tintColor = theme.primaryText
            button.backgroundColor = theme.controlBackground
            button.layer.cornerRadius = 16
            button.accessibilityLabel = label
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 32),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        titleLabel.textAlignment = .center
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = theme.secondaryText
        subtitleLabel.textAlignment = .center

        let subtitleRow = UIStackView(arrangedSubviews: [subtitleLabel, networkBars])
        subtitleRow.axis = .horizontal
        subtitleRow.alignment = .center
        subtitleRow.spacing = 6
        let center = UIStackView(arrangedSubviews: [titleLabel, subtitleRow])
        center.axis = .vertical
        center.alignment = .center
        center.spacing = 2
        center.translatesAutoresizingMaskIntoConstraints = false
        addSubview(center)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: theme.headerHeight),
            minimizeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            inviteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: minimizeButton.trailingAnchor, constant: 8),
            center.trailingAnchor.constraint(lessThanOrEqualTo: inviteButton.leadingAnchor, constant: -8),
        ])
    }
}

/// 顶部橙条（规范 §08）：「正在重连…」「连接已断开」「对方网络不佳」。橙底深字，圆角胶囊。
public final class IMTopBannerView: UIView {
    private let label = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        let theme = IMKitTheme.current
        backgroundColor = theme.warning
        layer.cornerRadius = 12
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = theme.overlayBackground
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /// apply 设文案；空串 = 隐藏。
    public func apply(text: String) {
        label.text = text
        accessibilityLabel = text
        isHidden = text.isEmpty
    }
}

/// 我们自己画的提示卡（规范 §06）：宽 270、圆角 16、标题 T3、正文 B1、两个横排动作。权限说明与被拒提示都用它。
public final class IMPromptCardView: UIView {
    public var onAnswer: ((Bool) -> Void)?
    public var onOpenSettings: (() -> Void)?

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public func apply(_ card: IMPromptCard) {
        titleLabel.text = card.title
        bodyLabel.text = card.body
        primaryButton.setTitle(card.primaryLabel, for: .normal)
        secondaryButton.setTitle(card.secondaryLabel, for: .normal)
        secondaryButton.isHidden = card.secondaryLabel.isEmpty
        // 麦克风被拒时能直接跳系统设置（iOS 有这条路，Web 没有）。
        settingsButton.isHidden = !(card.offersSettings && card.device == .microphone)
    }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.banner
        layer.cornerRadius = 16
        clipsToBounds = true
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = theme.primaryText
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        bodyLabel.font = .systemFont(ofSize: 15)
        bodyLabel.textColor = theme.secondaryText
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        text.axis = .vertical
        text.spacing = 6

        for (button, bold) in [(secondaryButton, false), (settingsButton, false), (primaryButton, true)] {
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: bold ? .bold : .regular)
            button.tintColor = theme.primaryText
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        settingsButton.setTitle("去设置", for: .normal)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [secondaryButton, settingsButton, primaryButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        let divider = UIView()
        divider.backgroundColor = UIColor(white: 1, alpha: 0.12)

        for view in [text, divider, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 270),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            divider.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            actions.topAnchor.constraint(equalTo: divider.bottomAnchor),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func primaryTapped() { onAnswer?(true) }
    @objc private func secondaryTapped() { onAnswer?(false) }
    @objc private func settingsTapped() {
        onOpenSettings?()
        onAnswer?(true)
    }
}
#endif
