#if canImport(UIKit)
import UIKit

/*
 控制条与标题栏的「3s 后淡出、任意触摸恢复」（规范 §07）。

 从 `IMCallOverlayViewController` 里抽出来的协作对象（CONVENTIONS §2）：那边已经顶着
 600 行红线，而这一小块——淡入淡出、拦触摸、一个定时器——是个自洽的关注点。
 **与 Android 的 `IMChromeGate` 同名同形**：这块逻辑两端漂过一次
 （2026-09-09 查出三处不一致），同名同形是为了下一次改动时一眼看得出哪边没跟上。

 # 判据在两处用，但只有一份

 `canAutoHide` 在**排定时与触发时各查一次**，缺哪一次都出过问题：
 · 只在触发时查（iOS 原先）：1v1 视频在 `connecting` 阶段版式已经是 `.video`，
   那时排下的定时器 3 秒后触发，而 phase 刚变 `.active`——控制条在**接通后不到 3 秒**
   就消失了，而规范说的是接通后 3s。
 · 只在排定时查（Android 原先）：`render` 在 `.ended` 时提前 return、走不到 set/arm，
   所以接通期排下的那一下不会被撤，会在**结束画面**上把标题栏一起淡掉。
 */
final class IMChromeGate {

    /// 跟着淡入淡出、**并且**要拦住触摸的（标题栏、控制条）。
    private let views: [UIView]
    /**
     只跟着淡入淡出的 layer（控制条底下那层渐变）。

     它不在「拦触摸」那一份里：`CALayer` 本来就不参与 hit test，
     而且它的 `isHidden` 归 `render` 管（视频版式且未结束才显示），这里插手会打架。
    */
    private let layers: [CALayer]
    /// 此刻允不允许自动隐藏。实现上是「版式是 video 且已接通」。
    private let canAutoHide: () -> Bool
    /// 可见性变了就叫一声，界面拿它抬 / 放小窗。
    private let onChanged: (Bool) -> Void

    private(set) var visible = true
    private var timer: DispatchSourceTimer?

    init(views: [UIView], layers: [CALayer],
         canAutoHide: @escaping () -> Bool, onChanged: @escaping (Bool) -> Void) {
        self.views = views
        self.layers = layers
        self.canAutoHide = canAutoHide
        self.onChanged = onChanged
    }

    /// **持有方释放时必须 cancel**（CONVENTIONS §5）。
    deinit { timer?.cancel() }

    /**
     显示 / 隐藏。`arm: false` 用于「非视频版式下永远可见」那条路——摆出来但不计时。

     隐藏之后 `isUserInteractionEnabled = false` 会让这棵子树整体退出 hit test，
     触摸落到下面那层去。**Android 那边做同一件事要置 `INVISIBLE`**：
     对 ViewGroup 设 `isEnabled = false` 既不传给子 View 也不拦派发，
     控制条淡出后五颗按钮（含挂断）全都还能点——那是 2026-09-09 真机查出来的 bug。
    */
    func set(visible: Bool, arm: Bool = true) {
        self.visible = visible
        UIView.animate(withDuration: IMKitTheme.current.fadeDuration) {
            for view in self.views { view.alpha = visible ? 1 : 0 }
            for layer in self.layers { layer.opacity = visible ? 1 : 0 }
        }
        for view in views { view.isUserInteractionEnabled = visible }
        onChanged(visible)
        if visible, arm { armAutoHide() } else { timer?.cancel() }
    }

    /// 排定 3 秒后收起。见类注释「判据在两处用」。
    func armAutoHide() {
        timer?.cancel()
        guard canAutoHide() else { return }
        let next = DispatchSource.makeTimerSource(queue: .main)
        next.schedule(deadline: .now() + IMKitTheme.current.autoHideDelay)
        next.setEventHandler { [weak self] in
            guard let self, self.canAutoHide() else { return }
            self.set(visible: false)
        }
        timer = next
        next.resume()
    }

    /// 撤掉待触发的那一下。
    func cancel() { timer?.cancel() }
}
#endif
