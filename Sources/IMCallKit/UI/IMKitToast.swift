#if canImport(UIKit)
import UIKit

/*
 一句轻提示，浮在最上层那个 window 上，2 秒后淡出。

 **为什么不用 `.hint`**：hint 画在通话界面里，通话收成悬浮球、人在宿主界面上时根本看不见
 （「你正在通话中」正是这种场景）。Kit 自己是独立 window 层（见 `IMCallWindow`），toast 同样不依赖宿主的任何 VC。
 不拦截触摸。
 */
enum IMKitToast {

    static func show(_ text: String) {
        guard let window = topWindow() else { return }
        let label = PaddedLabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 15)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -96),
            label.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -64),
        ])
        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }, completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 2, options: [], animations: { label.alpha = 0 },
                           completion: { _ in label.removeFromSuperview() })
        })
    }

    /// 前台活跃 scene 里最上层、可见的 window。
    private static func topWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.filter { !$0.isHidden }.max { $0.windowLevel < $1.windowLevel }
    }

    private final class PaddedLabel: UILabel {
        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.inset(by: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)))
        }
        override var intrinsicContentSize: CGSize {
            let s = super.intrinsicContentSize
            return CGSize(width: s.width + 32, height: s.height + 20)
        }
    }
}
#endif
