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

 # 这也是 Demo 选 UIKit 生命周期的原因

 建这个 window 要拿到 `UIWindowScene`，`SceneDelegate` 里直接就有；
 SwiftUI 的 App 生命周期得绕 `UIApplicationDelegateAdaptor` 去捞。
 */
public final class IMCallWindow {

    private var window: UIWindow?
    private let controller: IMCallController
    /// 悬浮小窗（最小化之后）。与全屏页共用一个 window，只是换根 VC。
    private var isShowing = false

    public init(controller: IMCallController) {
        self.controller = controller
        controller.addObserver(self)
    }

    /// present 把通话页盖上来。幂等。
    public func present(in scene: UIWindowScene?) {
        guard !isShowing else { return }
        guard let scene = scene ?? Self.activeScene() else {
            IMRTCLog.error("[Kit] 找不到 UIWindowScene，通话页没法显示")
            return
        }
        let window = UIWindow(windowScene: scene)
        /*
         **层级要压过 alert 但别压过状态栏**。
         `.alert` 那一档会盖住系统输入法与部分系统弹窗，通话页不需要那么高；
         `.normal + 1` 足够盖住宿主的一切，同时不影响系统 UI。
         */
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = IMCallOverlayViewController(controller: controller)
        window.makeKeyAndVisible()
        self.window = window
        isShowing = true
        IMRTCLog.info("[Kit] 通话页已显示")
    }

    /// dismiss 收掉通话页。
    ///
    /// **必须把 window 置 nil**：只 `isHidden = true` 的话它还在 scene 的 window 列表里，
    /// 键盘窗口的层级判断会受影响，而且下一通电话会叠出第二个。
    public func dismiss() {
        guard isShowing else { return }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        isShowing = false
        IMRTCLog.info("[Kit] 通话页已收起")
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
        // 宿主只管调 placeCall / joinMeeting，剩下的 Kit 自己接住。
        state.isVisible ? present(in: nil) : dismiss()
    }
}
#endif
