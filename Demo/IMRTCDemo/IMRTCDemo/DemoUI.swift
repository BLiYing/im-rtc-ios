import UIKit

/// Demo 几屏共用的小控件。**普通页面走系统风格**（草图 §01），不套 Kit 的深色主题。
enum DemoUI {

    static func field(placeholder: String, text: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.text = text
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.font = .systemFont(ofSize: 15)
        return field
    }

    static func button(_ title: String, _ action: Selector, _ target: Any) -> UIButton {
        let button = UIButton(type: .system)
        style(button, title: title, action: action, target: target)
        return button
    }

    static func style(_ button: UIButton, title: String, action: Selector, target: Any) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 8
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        button.addTarget(target, action: action, for: .touchUpInside)
    }

    static func note(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }

    /**
     「一句说明 + 一个开关」的身份卡行（合成画面、调试密钥登录共用，保证两个开关同列）。

     **开关抗压缩必须是 required、文案必须更低**：两者默认都是 750，文案一长
     （调试密钥那句要折两行）布局就可能去压开关，开关被挤出卡片右沿（真机 09-28）。
     */
    static func switchRow(_ text: String, _ toggle: UISwitch) -> UIStackView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    static func row(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        return stack
    }

    /// card 是一个带标题的分组。
    static func card(_ title: String, _ content: [UIView]) -> UIView {
        let header = UILabel()
        header.text = title
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [header] + content)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return card
    }

    /**
     scroll 把一个竖向 stack 放进可滚动的页面里。

     **底边钉 `keyboardLayoutGuide` 而不是安全区**：键盘弹起时可滚动区域跟着缩到键盘上沿，
     再由 `KeyboardAwareScrollView` 把正在输入的框滚进可见区——否则拨号页下半截的
     被叫 / call_id / 房间号三个框都会被键盘盖住，打字看不见（真机反馈 09-28）。
     键盘收起时这个 guide 的上沿就是安全区底边，行为与原来一致。
     */
    static func scroll(_ stack: UIStackView, in view: UIView) {
        let scroll = KeyboardAwareScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }
}

/// 开始输入、或键盘弹起 / 换尺寸之后，把自己里面正在输入的那个框滚进可见区。
/// 两个时机都要：键盘已经弹着时再点另一个框，不会再来一次 `keyboardDidShow`。
final class KeyboardAwareScrollView: UIScrollView {
    private var tokens: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification,
                     UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardDidChangeFrameNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 下一轮 runloop 再滚：keyboardLayoutGuide 缩短可视区的那次布局要先落地。
                DispatchQueue.main.async { self?.revealFirstResponder() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    private func revealFirstResponder() {
        guard window != nil, let field = firstResponderField(in: self) else { return }
        layoutIfNeeded()
        let rect = field.convert(field.bounds, to: self).insetBy(dx: 0, dy: -16)
        scrollRectToVisible(rect, animated: true)
    }

    private func firstResponderField(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is UITextField || view is UITextView { return view }
        for sub in view.subviews {
            if let hit = firstResponderField(in: sub) { return hit }
        }
        return nil
    }
}
