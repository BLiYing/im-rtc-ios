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

    public init(controller: IMCallController, config: IMCallKitConfig) {
        self.controller = controller
        self.config = config
        controller.addObserver(self)
    }

    deinit { bubbleTimer?.cancel() }

    // MARK: - 形态切换

    private func apply(_ state: IMCallViewState) {
        let wanted = desiredMode(for: state)
        if wanted != mode { transition(to: wanted, state: state) }
        // 同一形态内的刷新：横幅换来电人、悬浮球换时长。
        if wanted == .banner, let banner = window?.rootViewController?.view.subviews
            .first as? IMIncomingBanner {
            banner.apply(caller: state.peerUID, mediaType: state.mediaType)
        }
        if state.phase == .idle { bannerExpanded = false }
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
        banner.apply(caller: state.peerUID, mediaType: state.mediaType)
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
    }

    private func mountBubble(in host: UIViewController, scene: UIWindowScene,
                             state: IMCallViewState) {
        let bubble = IMFloatingBubble(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        let bounds = scene.coordinateSpace.bounds
        bubble.center = CGPoint(x: bounds.width - 8 - 28, y: 120)
        bubble.onExpand = { [weak self] in self?.controller.setMinimized(false) }
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
        let text: String
        if state.phase == .active {
            text = imFormatDuration(Int(Date().timeIntervalSince1970 - state.beganAt))
        } else {
            text = "…"
        }
        bubble?.apply(durationText: text, isVideo: state.mediaType == "video")
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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 全屏页模式下没设 hitTarget，一切照常。
        guard let hitTarget else { return hit }
        guard let hit, hit.isDescendant(of: hitTarget) else { return nil }
        return hit
    }
}
#endif
