#if canImport(UIKit)
import UIKit

/*
 悬浮球（交互稿 §03 M1）。通话页左上角收起后，通话缩成一个可拖的小窗贴在屏幕边上，点一下展开回全屏。
 **通话本身不受影响**——它只是换了个呈现。

 两种形态：语音通话是 **56 圆角球**（图标 + 等宽时长）；视频通话是 **90×120 缩略画面**，
 右下角叠时长——只放主讲人，层上界报 `l`，这么小的窗口订 h 层是纯烧带宽。

 **球体下面挂一颗 28 的红色挂断**：收进小窗之后没有它就只能先展开回全屏才能挂断，
 而「随手挂掉」正是小窗最常用的一件事。红色是危险动作的唯一颜色（规范 §01 danger）。

 # 为什么本体是「容器 + 球 + 挂断」三层

 挂断放在球体内部会被圆角裁掉、放在球外又要靠改写 `point(inside:)` 才点得到，
 而球上那个 `UITapGestureRecognizer`（点一下展开）还会把按钮的触摸整个吃掉——
 三件事凑在一起就是「按钮看不见、看见了也点不动」。所以本类是一个**透明容器**：
 球（`body`）在上、挂断在下，两个都在容器边界内；展开手势加了 delegate，
 落在按钮上的触摸不归它管。与 Android 的 `IMFloatingBubble` 同一个结构。

 拖完**吸附到最近的左右边缘**（离边 8）：停在屏幕中间会挡住宿主的内容。竖直方向夹在安全区内且上下各留 60。
 图标用 SF Symbols（`IMKitIcon`），**不用 emoji**——真机上 emoji 会渲染成方框问号。
 */
public final class IMFloatingBubble: UIView {

    public var onExpand: (() -> Void)?
    /// 小窗上的挂断。宿主不接的话按钮不出现——没有出口的按钮比没有按钮更糟。
    public var onHangup: (() -> Void)?
    /// 视频形态下远端缩略画面的载体。IMCallWindow 往这上面 attachView。
    public let renderView = UIView()

    /// 球体本身（圆 / 圆角矩形）。底色、圆角、阴影、视频缩略都在它身上，挂断在它外面。
    private let body = UIView()
    private let iconView = UIImageView()
    private let hangupButton = UIButton(type: .system)
    private let durationLabel = UILabel()
    private let stack = UIStackView()
    private var dragOffset = CGPoint.zero
    private var isVideo = false

    /// 挂断按钮的直径。28 是「拇指够得着」的下限（规范 §04 的小控件尺寸）。
    static let hangupSize: CGFloat = 28
    /// 球体与挂断之间的间隙。
    static let hangupGap: CGFloat = 4

    /// 容器的总高 = 球体高 + 间隙 + 挂断。`IMCallWindow` 建视图时要用同一个算法。
    public static func totalSize(bodySize: CGSize) -> CGSize {
        CGSize(width: bodySize.width, height: bodySize.height + hangupGap + hangupSize)
    }

    private var bodyHeightConstraint: NSLayoutConstraint!

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
        let bodySize = isVideo ? theme.bubbleVideoSize : CGSize(width: theme.bubbleSize, height: theme.bubbleSize)
        bounds = CGRect(origin: .zero, size: Self.totalSize(bodySize: bodySize))
        bodyHeightConstraint.constant = bodySize.height
        body.layer.cornerRadius = isVideo ? 14 : theme.bubbleSize / 2
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
        backgroundColor = .clear
        clipsToBounds = false

        body.backgroundColor = theme.overlayBackground
        body.layer.cornerRadius = theme.bubbleSize / 2
        body.layer.shadowColor = UIColor.black.cgColor
        body.layer.shadowOpacity = 0.35
        body.layer.shadowRadius = 10
        body.layer.shadowOffset = CGSize(width: 0, height: 4)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        bodyHeightConstraint = body.heightAnchor.constraint(equalToConstant: theme.bubbleSize)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyHeightConstraint,
        ])

        renderView.isHidden = true
        renderView.layer.cornerRadius = 14
        renderView.clipsToBounds = true
        renderView.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(renderView)

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
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: body.topAnchor),
            renderView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])

        hangupButton.setImage(IMKitIcon.phoneDown.image(pointSize: 13), for: .normal)
        hangupButton.tintColor = theme.primaryText
        hangupButton.backgroundColor = theme.danger
        hangupButton.layer.cornerRadius = Self.hangupSize / 2
        hangupButton.accessibilityLabel = "挂断"
        hangupButton.addTarget(self, action: #selector(hangupTapped), for: .touchUpInside)
        hangupButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hangupButton)
        NSLayoutConstraint.activate([
            hangupButton.widthAnchor.constraint(equalToConstant: Self.hangupSize),
            hangupButton.heightAnchor.constraint(equalToConstant: Self.hangupSize),
            hangupButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            hangupButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 展开手势只认球体：不加 delegate 的话它会把挂断按钮的触摸整个吃掉。
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        addGestureRecognizer(tap)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
        body.isAccessibilityElement = true
        body.accessibilityLabel = "通话中，点击展开"
        body.accessibilityTraits = .button
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard isVideo else { return }
        // 视频形态：时长贴右下角（规范 §06「悬浮球（视频）」）。
        stack.frame = CGRect(x: body.bounds.width - 48 - 5, y: body.bounds.height - 16 - 5, width: 48, height: 16)
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
        let minY = self.bounds.height / 2 + 60
        let maxY = bounds.height - self.bounds.height / 2 - 60
        let targetY = min(max(center.y, minY), maxY)
        UIView.animate(withDuration: IMKitTheme.current.snapDuration, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0.5) {
            self.center = CGPoint(x: targetX, y: targetY)
        }
    }
}

/// 展开手势的 delegate：落在挂断按钮上的触摸不归它管（否则按钮永远收不到点击）。
extension IMFloatingBubble: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldReceive touch: UITouch) -> Bool {
        !(touch.view?.isDescendant(of: hangupButton) ?? false)
    }
}
#endif
