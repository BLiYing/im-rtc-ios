#if canImport(UIKit)
import UIKit
import IMCallEngine

/**
 音频路由面板：出现第三条路由时从底部升起的那张设备列表（设计稿 §04 v3.5）。

 **iOS 自己画，不用系统的 `AVRoutePickerView`**——2026-09-22 试过，那个控件让系统直接改路由、
 完全绕开 `RTCAudioSession`，真机上把两个方向的声音都打没了（CLIENT_PARITY `[^audioroute]` v1.59）。
 这里点一行只调 `IMCallController.selectAudioRoute(_:)`，最终落到 Engine 的
 `setAudioRoute(_:)`，全程在 libwebrtc 自己的会话管理里，与 Android 的面板同一套语义。

 版式照设计稿：上圆角 20、行高 56、左右各留 20、左图标 24 + 间距 14 + 名字 15/regular、
 当前项右侧一枚 20 的勾（accent 色）、上方压一层黑 45% 的遮罩。
 **点任意一项立即切换并收起；点面板外 = 取消。面板里没有「取消」按钮。**
 */
final class IMAudioRoutePanel: UIView {

    private let dimmer = UIView()
    private let sheet = UIView()
    private let stack = UIStackView()
    private let onPick: (IMAudioRoute) -> Void
    private var sheetBottom: NSLayoutConstraint?

    init(routes: [IMAudioRoute], current: IMAudioRoute?, onPick: @escaping (IMAudioRoute) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        build(routes: routes, current: current)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /// present 挂到某个视图上并升起来。收起走 `dismiss()`。
    func present(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        // 先摆到屏幕外再升起来，避免第一帧闪现在最终位置。
        host.layoutIfNeeded()
        sheetBottom?.constant = sheet.bounds.height
        layoutIfNeeded()
        dimmer.alpha = 0
        sheetBottom?.constant = 0
        UIView.animate(withDuration: IMKitTheme.current.pressDuration * 2, delay: 0,
                       options: [.curveEaseOut]) {
            self.dimmer.alpha = 1
            self.layoutIfNeeded()
        }
    }

    func dismiss() {
        sheetBottom?.constant = sheet.bounds.height
        UIView.animate(withDuration: IMKitTheme.current.pressDuration * 2, delay: 0,
                       options: [.curveEaseIn]) {
            self.dimmer.alpha = 0
            self.layoutIfNeeded()
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    private func build(routes: [IMAudioRoute], current: IMAudioRoute?) {
        let theme = IMKitTheme.current

        dimmer.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dimmer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimmer)
        // 点面板外 = 取消（设计稿：面板里没有「取消」按钮）。
        dimmer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onDimmerTap)))

        // 主题里没有设计稿那个 `surface`，用同语义的 banner（深色卡片底）。
        sheet.backgroundColor = theme.banner
        sheet.layer.cornerRadius = 20
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.clipsToBounds = true
        sheet.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sheet)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.addSubview(stack)

        for route in routes {
            stack.addArrangedSubview(IMAudioRouteRow(route: route, isCurrent: route == current) { [weak self] picked in
                // 点任意一项：立即切换并收起。
                self?.onPick(picked)
                self?.dismiss()
            })
        }

        let bottom = sheet.bottomAnchor.constraint(equalTo: bottomAnchor)
        sheetBottom = bottom
        NSLayoutConstraint.activate([
            dimmer.topAnchor.constraint(equalTo: topAnchor),
            dimmer.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmer.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmer.bottomAnchor.constraint(equalTo: bottomAnchor),

            sheet.leadingAnchor.constraint(equalTo: leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,

            // 上下留白 16 + 安全区（设计稿：高度自适应 = 行数 × 56 + 32 + 安全区）。
            stack.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: sheet.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    @objc private func onDimmerTap() { dismiss() }
}

/// 面板里的一行：左图标 24 + 间距 14 + 设备名 15/regular，当前项右侧一枚 20 的勾。
private final class IMAudioRouteRow: UIControl {
    private let route: IMAudioRoute
    private let onTap: (IMAudioRoute) -> Void

    init(route: IMAudioRoute, isCurrent: Bool, onTap: @escaping (IMAudioRoute) -> Void) {
        self.route = route
        self.onTap = onTap
        super.init(frame: .zero)
        build(isCurrent: isCurrent)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    private func build(isCurrent: Bool) {
        let theme = IMKitTheme.current
        let icon = UIImageView(image: imRouteIcon(route.kind).image(pointSize: 24))
        icon.tintColor = theme.primaryText
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = imRouteDisplayName(route)
        label.font = .systemFont(ofSize: 15)
        label.textColor = theme.primaryText
        label.lineBreakMode = .byTruncatingMiddle

        let check = UIImageView(image: IMKitIcon.check.image(pointSize: 20))
        // 设计稿的 accent 在本 Kit 对应 accept 这支绿。
        check.tintColor = theme.accept
        check.isHidden = !isCurrent
        check.contentMode = .scaleAspectFit

        for view in [icon, label, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -12),

            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 20),
            check.heightAnchor.constraint(equalToConstant: 20),
        ])
        isAccessibilityElement = true
        accessibilityLabel = label.text
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
    }

    @objc private func tapped() { onTap(route) }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? IMKitTheme.current.controlBackground : .clear }
    }
}

/// 路由的字形（设计稿 §05 图标库）。
func imRouteIcon(_ kind: IMAudioRouteKind) -> IMKitIcon {
    switch kind {
    case .earpiece: return .earpiece
    case .speaker: return .speaker
    case .wiredHeadset: return .headphones
    case .bluetooth: return .bluetooth
    }
}
#endif
