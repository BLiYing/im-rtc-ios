#if canImport(UIKit)
import UIKit
import IMCallEngine

/*
 Kit 的**独立 window 层**。CONVENTIONS §8：

   Kit 的所有页面挂在独立 window 层，不入宿主导航栈——任何页面都能被来电覆盖。

 # 为什么必须是另一个 window，而不是 present 一个 VC

 present 出来的东西挂在宿主某个 VC 上：宿主一旦 push/pop/dismiss，通话页就可能
 被连带掀掉或者盖住。而通话是**跨越宿主任何界面**的——用户在聊天页、设置页、
 甚至另一个 modal 里，来电都得能盖上来。另开一个 window 是唯一能做到这件事的办法。

 # 三种形态，同一个状态

 全屏页、来电横幅、悬浮球都只是 `IMCallViewState` 的不同呈现：
   · 来电 + 横幅开关开 + 没展开  → 横幅（贴顶，不挡内容）
   · 收进小窗                     → 悬浮球（可拖，点开还原）
   · 其余                         → 全屏页
 形态之间切换只换 window 的 frame 与根视图，**通话本身不受影响**。

 # 这也是 Demo 选 UIKit 生命周期的原因

 建这个 window 要拿到 `UIWindowScene`，`SceneDelegate` 里直接就有；
 SwiftUI 的 App 生命周期得绕 `UIApplicationDelegateAdaptor` 去捞。
 */
public final class IMCallWindow {

    private enum Mode: Equatable { case hidden, banner, bubble, fullscreen }

    private var window: UIWindow?
    private var mode: Mode = .hidden
    private let controller: IMCallController
    private let config: IMCallKitConfig
    /// 横幅被点开之后，这一通来电就一直全屏，不再缩回横幅。
    private var bannerExpanded = false
    /// 悬浮球每秒刷时长。**持有方释放时必须 cancel**（CONVENTIONS §5）。
    private var bubbleTimer: DispatchSourceTimer?
    private weak var bubble: IMFloatingBubble?
    /// 悬浮球（视频形态）里挂着哪个人的画面。换主讲人时先摘再挂。
    private var bubbleAttachedUID = ""
    /// 横幅 5s 不处理就升级为全屏来电页（交互稿 §06）。
    private var bannerEscalateTimer: DispatchSourceTimer?
    /// 权限说明 / 被拒卡的遮罩。叠在任何形态之上。
    private var promptDimmer: UIView?

    public init(controller: IMCallController, config: IMCallKitConfig) {
        self.controller = controller
        self.config = config
        controller.addObserver(self)
    }

    deinit {
        bubbleTimer?.cancel()
        bannerEscalateTimer?.cancel()
    }

    // MARK: - 形态切换

    private func apply(_ state: IMCallViewState) {
        let wanted = desiredMode(for: state)
        if wanted != mode { transition(to: wanted, state: state) }
        // 同一形态内的刷新：横幅换来电人、悬浮球换时长。
        if wanted == .banner, let banner = window?.rootViewController?.view.subviews
            .first as? IMIncomingBanner {
            banner.apply(caller: state.participants.first?.uid ?? state.peerUID,
                         mediaType: state.mediaType, isGroup: state.isGroup)
        }
        if wanted == .bubble { refreshBubble(state) }
        if state.phase == .idle { bannerExpanded = false }
        renderPrompt(controller.promptCard)
    }

    /// renderPrompt 画权限说明 / 被拒卡（规范 §06）。卡叠在最上面，**不受形态限制**：它出现在拨出之前、接听之前。
    private func renderPrompt(_ card: IMPromptCard?) {
        guard let card else {
            promptDimmer?.removeFromSuperview()
            promptDimmer = nil
            return
        }
        guard promptDimmer == nil else { return }
        guard let scene = Self.activeScene() else { return }
        let window = self.window ?? makeWindow(in: scene)
        if window.rootViewController == nil {
            let host = UIViewController()
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.frame = scene.coordinateSpace.bounds
            window.makeKeyAndVisible()
        }
        guard let host = window.rootViewController?.view else { return }
        let dimmer = UIView()
        dimmer.backgroundColor = UIColor(red: 8 / 255, green: 10 / 255, blue: 16 / 255, alpha: 0.42)
        let cardView = IMPromptCardView()
        cardView.apply(card)
        cardView.onAnswer = { ok in card.answer(ok) }
        cardView.onOpenSettings = {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        dimmer.translatesAutoresizingMaskIntoConstraints = false
        cardView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(dimmer)
        dimmer.addSubview(cardView)
        NSLayoutConstraint.activate([
            dimmer.topAnchor.constraint(equalTo: host.topAnchor), dimmer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            dimmer.leadingAnchor.constraint(equalTo: host.leadingAnchor), dimmer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            cardView.centerXAnchor.constraint(equalTo: dimmer.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: dimmer.centerYAnchor, constant: -40),
        ])
        // 横幅 / 悬浮球模式下只有那一小块吃触摸；卡出来时整屏都要吃。
        (window as? IMPassthroughWindow)?.promptTarget = dimmer
        promptDimmer = dimmer
    }

    private func desiredMode(for state: IMCallViewState) -> Mode {
        guard state.isVisible else { return .hidden }
        if state.isMinimized, config.floatingWindow { return .bubble }
        if state.phase == .incoming, config.bannerFirst, !bannerExpanded { return .banner }
        return .fullscreen
    }

    private func transition(to wanted: Mode, state: IMCallViewState) {
        bubbleTimer?.cancel()
        bubbleTimer = nil
        bannerEscalateTimer?.cancel()
        bannerEscalateTimer = nil
        if !bubbleAttachedUID.isEmpty {
            controller.attachView(bubbleAttachedUID, to: nil)
            bubbleAttachedUID = ""
        }
        promptDimmer?.removeFromSuperview()
        promptDimmer = nil
        guard wanted != .hidden else { dismiss(); return }
        guard let scene = Self.activeScene() else {
            IMRTCLog.error("[Kit] 找不到 UIWindowScene，通话页没法显示")
            return
        }
        let window = self.window ?? makeWindow(in: scene)
        let host = UIViewController()
        host.view.backgroundColor = .clear

        switch wanted {
        case .fullscreen:
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = IMCallOverlayViewController(controller: controller)
        case .banner:
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            mountBanner(in: host, scene: scene, state: state)
        case .bubble:
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            mountBubble(in: host, scene: scene, state: state)
        case .hidden:
            break
        }
        window.makeKeyAndVisible()
        mode = wanted
        IMRTCLog.info("[Kit] 通话界面形态", ["mode": String(describing: wanted)])
    }

    private func makeWindow(in scene: UIWindowScene) -> UIWindow {
        let window = IMPassthroughWindow(windowScene: scene)
        /*
         **层级要压过 alert 但别压过状态栏**。`.alert` 那一档会盖住系统输入法与
         部分系统弹窗，通话页不需要那么高；`.normal + 1` 足够盖住宿主的一切。
         */
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        self.window = window
        return window
    }

    /// dismiss 收掉整个 window。
    ///
    /// **必须把 window 置 nil**：只 `isHidden = true` 的话它还在 scene 的 window 列表里，
    /// 键盘窗口的层级判断会受影响，而且下一通电话会叠出第二个。
    private func dismiss() {
        // 卡不随通话页走：拨出前被拒的那张卡此刻可能还在，收掉 window 前先把它放回 nil，下一次再画。
        promptDimmer = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        mode = .hidden
        IMRTCLog.info("[Kit] 通话页已收起")
    }

    // MARK: - 横幅与悬浮球

    private func mountBanner(in host: UIViewController, scene: UIWindowScene,
                             state: IMCallViewState) {
        let banner = IMIncomingBanner()
        banner.apply(caller: state.participants.first?.uid ?? state.peerUID,
                     mediaType: state.mediaType, isGroup: state.isGroup)
        banner.onAccept = { [weak self] in self?.controller.accept() }
        banner.onReject = { [weak self] in self?.controller.reject() }
        banner.onExpand = { [weak self] in
            guard let self else { return }
            self.bannerExpanded = true
            self.apply(self.controller.state)
        }
        banner.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(banner)
        let guide = host.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
        ])
        (window as? IMPassthroughWindow)?.hitTarget = banner
        // 从顶部滑入——横幅突然出现像 bug，滑入才像通知。
        banner.transform = CGAffineTransform(translationX: 0, y: -120)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0.6) { banner.transform = .identity }
        // 5s 不处理升级为全屏来电页（交互稿 §06）。
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.controller.state.phase == .incoming else { return }
            self.bannerExpanded = true
            self.apply(self.controller.state)
        }
        bannerEscalateTimer = timer
        timer.resume()
    }

    private func mountBubble(in host: UIViewController, scene: UIWindowScene,
                             state: IMCallViewState) {
        let theme = IMKitTheme.current
        let isVideo = state.mediaType == "video"
        let size = isVideo ? theme.bubbleVideoSize : CGSize(width: theme.bubbleSize, height: theme.bubbleSize)
        let bubble = IMFloatingBubble(frame: CGRect(origin: .zero, size: size))
        let bounds = scene.coordinateSpace.bounds
        bubble.center = CGPoint(x: bounds.width - 8 - size.width / 2, y: 120 + size.height / 2)
        bubble.onExpand = { [weak self] in self?.controller.setMinimized(false) }
        // 小窗上的红色挂断走与红按钮同一条路（`imEndAction` 分辨四种场合），
        // **不能直接 hangup**：会议房里没有 call，那样会被本地拒成 2005。
        bubble.onHangup = { [weak self] in self?.controller.end() }
        host.view.addSubview(bubble)
        self.bubble = bubble
        (window as? IMPassthroughWindow)?.hitTarget = bubble
        refreshBubble(state)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refreshBubble(self.controller.state)
        }
        bubbleTimer = timer
        timer.resume()
    }

    private func refreshBubble(_ state: IMCallViewState) {
        guard let bubble else { return }
        let text: String
        if state.phase == .active {
            text = imFormatDuration(Int(Date().timeIntervalSince1970 - state.beganAt))
        } else {
            text = "…"
        }
        bubble.apply(durationText: text, isVideo: state.mediaType == "video")
        // 视频形态只放主讲人（1v1 就是对端）：这么小的窗口订 h 层是纯烧带宽，报 l。
        guard state.mediaType == "video" else { return }
        let speaker = state.participants.first { $0.isSpeaking } ?? state.participants.first
        let uid = speaker?.uid ?? ""
        guard uid != bubbleAttachedUID else { return }
        if !bubbleAttachedUID.isEmpty { controller.attachView(bubbleAttachedUID, to: nil) }
        bubbleAttachedUID = uid
        guard !uid.isEmpty else { return }
        controller.attachView(uid, to: bubble.renderView)
        controller.reportLayer(uid, "l")
    }

    /// activeScene 找当前活跃的前台 scene。
    ///
    /// 挑 `foregroundActive` 而不是随便取第一个：多 scene（iPad 分屏）时
    /// 取错的那个可能根本不在屏幕上，通话页就"显示成功了"但没人看得见。
    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

extension IMCallWindow: IMCallControllerObserver {
    public func callController(_ controller: IMCallController, didChange state: IMCallViewState) {
        // 界面的出现与消失**由状态驱动**，不由调用方记流程。
        apply(state)
    }
}

/*
 横幅和悬浮球模式下，window 铺满全屏但**只有那一小块吃触摸**——
 其余区域的点击要穿透给宿主，不然一个 56pt 的小球把整个 App 都挡住了。
 */
private final class IMPassthroughWindow: UIWindow {
    weak var hitTarget: UIView?
    /// 提示卡的遮罩出来时整屏都要吃触摸，不管当前是横幅还是悬浮球。
    weak var promptTarget: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let promptTarget, promptTarget.superview != nil { return hit ?? promptTarget }
        // 全屏页模式下没设 hitTarget，一切照常。
        guard let hitTarget else { return hit }
        guard let hit, hit.isDescendant(of: hitTarget) else { return nil }
        return hit
    }
}
#endif
