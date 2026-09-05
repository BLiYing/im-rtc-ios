import UIKit

/*
 **纯代码建 window，没有 storyboard。**

 不是架构要求，是干活方便：Demo 那几屏改起来很频繁，而 storyboard 是一坨
 带 UUID 的自动生成 XML，改它比改 Swift 痛苦得多，diff 也读不了。

 顺带说清一件常被混淆的事：**Kit 的页面不挂在这里**。
 Kit 自己在同一个 `UIWindowScene` 上另建一个 window（CONVENTIONS §8），
 这样来电能覆盖宿主的任何页面，也不会被塞进宿主的导航栈。
 Demo 这个 window 只承载「宿主本来就该自己写的那部分」：登录、拨号、通话记录。
 */
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        // 草图 §02 的三个 tab：拨号 / 记录 / 设置。登录也在拨号页的身份卡里。
        let tabs = UITabBarController()
        tabs.viewControllers = [
            nav(DialerViewController(), "拨号", "phone"),
            nav(HistoryViewController(), "记录", "clock"),
            nav(SettingsViewController(), "设置", "gearshape"),
        ]
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window
    }

    private func nav(_ root: UIViewController, _ title: String, _ icon: String) -> UINavigationController {
        let nav = UINavigationController(rootViewController: root)
        nav.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: icon), tag: 0)
        return nav
    }
}
