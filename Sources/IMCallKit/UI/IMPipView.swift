#if canImport(UIKit)
import UIKit

/*
 1v1 视频里浮在角上的那块小画面（交互稿 §04）：单击回调（互换由调用方做——这个视图不知道自己装的是
 本端还是对端）、**长按 350ms 进入拖动态**、松手吸附到最近的角、控制条显示时下面两个角上移 88。

 # 为什么拖动要先长按

 小窗只有 96 宽，手指本身就有十来 pt 的抖动。不加长按的话，用户想「点一下互换」十次里有三次
 会被判成拖动——小窗歪一点点然后弹回去，他不知道自己做错了什么。长按是给「移动」这个低频动作
 加的门槛，换来「互换」这个高频动作永远准。

 位置算术在 `Layout/IMPipLayout.swift`（纯函数，有单测，与 Web 同一份）；这里只负责手势与动画。
 */
public final class IMPipView: UIView {

    /// 里面装的内容（一个格子）。互换时把另一个格子塞进来，**不重建格子**——重建会让媒体层挂着的渲染视图重来，画面会闪。
    public private(set) var content: UIView?
    public var onTap: (() -> Void)?
    /// 停在哪个角。只记这一通（视图销毁就忘）。
    public private(set) var corner: IMPipCorner = .default
    /// 控制条此刻是否显示——显示时下面两个角要上移。
    public var liftsForControls = false {
        didSet { if !isDragging { snap(animated: true) } }
    }

    private var isDragging = false
    private var dragStart = CGPoint.zero
    private var frameAtDragStart = CGRect.zero
    private var ghosts: [UIView] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    private func build() {
        let theme = IMKitTheme.current
        layer.cornerRadius = theme.pipCornerRadius
        layer.borderWidth = 1.5
        layer.borderColor = UIColor(white: 1, alpha: 0.55).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 13
        layer.shadowOffset = CGSize(width: 0, height: 10)
        clipsToBounds = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
        longPress.minimumPressDuration = theme.longPressDelay
        // 手指抖动超过 8pt 就不算长按（与 Web 的 TOUCH_JITTER 同值）。
        longPress.allowableMovement = 8
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "本端画面"
        accessibilityHint = "轻点两下互换，轻点两下并按住可移动"
    }

    /// setContent 换里面装的格子。传 nil 清空。
    public func setContent(_ view: UIView?) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        content = view
        guard let view else { return }
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = IMKitTheme.current.pipCornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 容器尺寸变了（转屏、首次布局）就按当前角重摆。调用方在 `viewDidLayoutSubviews` 里调。
    public func layoutInContainer() {
        guard !isDragging else { return }
        snap(animated: false)
    }

    /// pipSize 是按容器形状算出来的尺寸。
    private var pipSize: IMPipSize {
        let bounds = superview?.bounds ?? .zero
        return imPipSize(containerWidth: bounds.width, containerHeight: bounds.height)
    }

    private func restFrame(for corner: IMPipCorner) -> CGRect {
        let bounds = superview?.bounds ?? .zero
        let size = pipSize
        let origin = imPipOrigin(corner, size: size, containerWidth: bounds.width, containerHeight: bounds.height,
                                 lift: liftsForControls ? IMPipLift : 0)
        return CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    private func snap(animated: Bool) {
        let target = restFrame(for: corner)
        guard animated else { frame = target; return }
        UIView.animate(withDuration: IMKitTheme.current.snapDuration, delay: 0,
                       usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            self.frame = target
            self.transform = .identity
        }
    }

    @objc private func tapped() { onTap?() }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard let container = superview else { return }
        let point = gesture.location(in: container)
        switch gesture.state {
        case .began:
            // 进入拖动态：放大 1.04、阴影加深、轻触觉反馈，四角浮现虚线框（交互稿 §04 S3）。
            isDragging = true
            dragStart = point
            frameAtDragStart = frame
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showGhosts(in: container)
            UIView.animate(withDuration: IMKitTheme.current.pressDuration) {
                self.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
                self.layer.shadowOpacity = 0.6
            }
        case .changed:
            let bounds = container.bounds
            let origin = imClampPipOrigin(
                IMPipPoint(x: frameAtDragStart.origin.x + point.x - dragStart.x,
                           y: frameAtDragStart.origin.y + point.y - dragStart.y),
                size: pipSize, containerWidth: bounds.width, containerHeight: bounds.height)
            frame.origin = CGPoint(x: origin.x, y: origin.y)
        case .ended, .cancelled, .failed:
            // 松手吸附到**最近的角**（按小窗中心算），不是最近的边。
            let bounds = container.bounds
            corner = imNearestCorner(IMPipPoint(x: frame.midX, y: frame.midY),
                                     containerWidth: bounds.width, containerHeight: bounds.height)
            isDragging = false
            hideGhosts()
            layer.shadowOpacity = 0.45
            snap(animated: true)
        default:
            break
        }
    }

    private func showGhosts(in container: UIView) {
        hideGhosts()
        for c in IMPipCorner.allCases {
            let ghost = UIView(frame: restFrame(for: c))
            ghost.layer.cornerRadius = IMKitTheme.current.pipCornerRadius
            ghost.layer.borderWidth = 1.5
            ghost.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
            ghost.isUserInteractionEnabled = false
            container.insertSubview(ghost, belowSubview: self)
            ghosts.append(ghost)
        }
    }

    private func hideGhosts() {
        ghosts.forEach { $0.removeFromSuperview() }
        ghosts = []
    }
}
#endif
