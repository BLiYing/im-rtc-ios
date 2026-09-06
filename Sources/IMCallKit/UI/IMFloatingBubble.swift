#if canImport(UIKit)
import UIKit

/*
 悬浮球（交互稿 §03 M1）。通话页左上角收起后，通话缩成一个可拖的小窗贴在屏幕边上，点一下展开回全屏。
 **通话本身不受影响**——它只是换了个呈现。

 两种形态：语音通话是 **56 圆角球**（图标 + 等宽时长）；视频通话是 **90×120 缩略画面**，
 右下角叠时长——只放主讲人，层上界报 `l`，这么小的窗口订 h 层是纯烧带宽。

 右上角恒有一颗 **22 的红色挂断**：收进小窗之后没有它就只能先展开回全屏才能挂断，
 而「随手挂掉」正是小窗最常用的一件事。红色是危险动作的唯一颜色（规范 §01 danger）。

 拖完**吸附到最近的左右边缘**（离边 8）：停在屏幕中间会挡住宿主的内容。竖直方向夹在安全区内且上下各留 60。
 图标用 SF Symbols（`IMKitIcon`），**不用 emoji**——真机上 emoji 会渲染成方框问号。
 */
public final class IMFloatingBubble: UIView {

    public var onExpand: (() -> Void)?
    /// 小窗上的挂断。宿主不接的话按钮不出现——没有出口的按钮比没有按钮更糟。
    public var onHangup: (() -> Void)?
    /// 视频形态下远端缩略画面的载体。IMCallWindow 往这上面 attachView。
    public let renderView = UIView()

    private let iconView = UIImageView()
    private let hangupButton = UIButton(type: .system)
    private let durationLabel = UILabel()
    private let stack = UIStackView()
    private var dragOffset = CGPoint.zero
    private var isVideo = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    /// apply 刷新时长与形态。形态变了会改自身尺寸（调用方随后 snap 一次即可）。
    public func apply(durationText: String, isVideo: Bool) {
        let theme = IMKitTheme.current
        durationLabel.text = durationText
        iconView.image = (isVideo ? IMKitIcon.video : IMKitIcon.phone).image(pointSize: 18)
        guard isVideo != self.isVideo else { return }
        self.isVideo = isVideo
        renderView.isHidden = !isVideo
        iconView.isHidden = isVideo
        let size = isVideo ? theme.bubbleVideoSize : CGSize(width: theme.bubbleSize, height: theme.bubbleSize)
        bounds = CGRect(origin: .zero, size: size)
        layer.cornerRadius = isVideo ? 14 : theme.bubbleSize / 2
        // 视频形态：时长挪到右下角的小标签里。
        stack.axis = .vertical
        if isVideo {
            durationLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            durationLabel.backgroundColor = theme.scrim
            durationLabel.layer.cornerRadius = 5
            durationLabel.clipsToBounds = true
        } else {
            durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            durationLabel.backgroundColor = .clear
        }
        setNeedsLayout()
    }

    private func build() {
        let theme = IMKitTheme.current
        backgroundColor = theme.overlayBackground
        layer.cornerRadius = theme.bubbleSize / 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)
        clipsToBounds = false

        renderView.isHidden = true
        renderView.layer.cornerRadius = 14
        renderView.clipsToBounds = true
        renderView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderView)

        iconView.tintColor = theme.primaryText
        iconView.contentMode = .center
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        durationLabel.textColor = theme.primaryText
        durationLabel.textAlignment = .center

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(durationLabel)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: topAnchor),
            renderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        hangupButton.setImage(IMKitIcon.phoneDown.image(pointSize: 11), for: .normal)
        hangupButton.tintColor = theme.primaryText
        hangupButton.backgroundColor = theme.danger
        hangupButton.layer.cornerRadius = 11
        hangupButton.accessibilityLabel = "挂断"
        hangupButton.addTarget(self, action: #selector(hangupTapped), for: .touchUpInside)
        hangupButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hangupButton)
        NSLayoutConstraint.activate([
            hangupButton.widthAnchor.constraint(equalToConstant: 22),
            hangupButton.heightAnchor.constraint(equalToConstant: 22),
            hangupButton.topAnchor.constraint(equalTo: topAnchor, constant: -6),
            hangupButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 6),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
        isAccessibilityElement = true
        accessibilityLabel = "通话中，点击展开"
        accessibilityTraits = .button
    }

    /// 挂断按钮探出球体 6pt，默认命中测试到不了它——这里把它捞回来。
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || hangupButton.frame.contains(point)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard isVideo else { return }
        // 视频形态：时长贴右下角（规范 §06「悬浮球（视频）」）。
        stack.frame = CGRect(x: bounds.width - 48 - 5, y: bounds.height - 16 - 5, width: 48, height: 16)
        durationLabel.frame = stack.bounds
    }

    @objc private func tapped() { onExpand?() }

    @objc private func hangupTapped() { onHangup?() }

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

    /// snapToEdge 吸附到最近的左右边缘，并夹在安全区内。四端同一组弹簧参数（阻尼 .8 / 初速 .5）。
    public func snapToEdge(in bounds: CGRect) {
        let half = bounds.width / 2
        let inset = bounds.width * 0.5 - 8 - self.bounds.width / 2 // 离边缘 8pt
        let targetX = center.x < half ? bounds.midX - inset : bounds.midX + inset
        let minY = self.bounds.height / 2 + 60, maxY = bounds.height - self.bounds.height / 2 - 60
        let targetY = min(max(center.y, minY), maxY)
        UIView.animate(withDuration: IMKitTheme.current.snapDuration, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0.5) {
            self.center = CGPoint(x: targetX, y: targetY)
        }
    }
}
#endif
