#if canImport(UIKit)
import UIKit

/*
 悬浮球。草图 §04：通话页左上角 ⌄ 收起后，通话缩成一个可拖的小球贴在屏幕边上，
 显示时长，点一下展开回全屏。**通话本身不受影响**——它只是换了个呈现。

 拖完**吸附到最近的左右边缘**：停在屏幕中间会挡住宿主的内容。
 */
public final class IMFloatingBubble: UIView {

    public var onExpand: (() -> Void)?

    private let iconLabel = UILabel()
    private let durationLabel = UILabel()
    private var dragOffset = CGPoint.zero

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    public func apply(durationText: String, isVideo: Bool) {
        durationLabel.text = durationText
        iconLabel.text = isVideo ? "📹" : "📞"
    }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.overlayBackground
        layer.cornerRadius = 28
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        iconLabel.font = .systemFont(ofSize: 20)
        iconLabel.textAlignment = .center
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = theme.primaryText
        durationLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [iconLabel, durationLabel])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
        isAccessibilityElement = true
        accessibilityLabel = "通话中，点击展开"
        accessibilityTraits = .button
    }

    @objc private func tapped() { onExpand?() }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let window = superview else { return }
        let point = pan.location(in: window)
        switch pan.state {
        case .began:
            dragOffset = CGPoint(x: point.x - center.x, y: point.y - center.y)
        case .changed:
            center = CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
        case .ended, .cancelled:
            snapToEdge(in: window.bounds)
        default:
            break
        }
    }

    /// snapToEdge 吸附到最近的左右边缘，并夹在安全区内。
    private func snapToEdge(in bounds: CGRect) {
        let half = bounds.width / 2
        let inset = bounds.width * 0.5 - 8 - self.bounds.width / 2 // 离边缘 8pt
        let targetX = center.x < half ? bounds.midX - inset : bounds.midX + inset
        let minY = self.bounds.height / 2 + 60, maxY = bounds.height - self.bounds.height / 2 - 60
        let targetY = min(max(center.y, minY), maxY)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0.5) {
            self.center = CGPoint(x: targetX, y: targetY)
        }
    }
}
#endif
