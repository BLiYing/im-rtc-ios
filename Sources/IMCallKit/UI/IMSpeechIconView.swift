import Foundation
#if canImport(UIKit)
import UIKit

/**
 名牌气泡里那枚说话 / 静音的小信号。**九宫格与会议里才有，1v1 不用**（2026-09-09 拍板）。

 # 为什么不是绿描边了

 原先「谁在说话」是整格绿描边 + 绿底名牌 + 名字加粗：三处大面积变化同时发生，
 视线被拽走；几个人轮流说话时整屏在闪。改成名字右边一枚 9×10 的图标之后，
 画面与名牌底色纹丝不动，**整个格子里唯一的绿就是这枚图标**。

 # 为什么是竖条不是麦克风

 麦克风说的是「他有麦克风」，竖条说的是「他此刻正在出声」——而且能把音量编码进条高。

 # 三种状态，永远占位

 安静时什么都不画，但**照样占 9×10**（2026-09-09 拍板：留位）。
 不留位的话名字会随说话左右跳，比图标本身更晃眼。

 # 收声要拖一拍

 服务端 300ms 一次全量快照（协议 §3.5）。一句话里的换气会让人短暂掉出名单——
 **直接跟着灭就是闪烁**。所以停的时候拖 `holdSeconds` 再灭，起的时候立刻亮。
 */
final class IMSpeechIconView: UIView {

    /// 三根条各自的图层。**用图层不用子视图**：只做 scale 动画，走不到布局那一层。
    private let bars: [CALayer] = (0..<3).map { _ in CALayer() }
    private let micSlash = UIImageView()
    /**
     「麦克风开着、没在说话」——**常态，所以要退到背景里**。

     它挂在每一个格子上、绝大多数时候都在，画得太显眼就成了新的干扰源，
     而这次改版的出发点正是减少干扰。所以用低对比度的白（`micOnAlpha`），
     只有说话那枚是亮绿色。
     */
    private let micOn = UIImageView()
    private var isAnimating = false
    private var quietWork: DispatchWorkItem?
    /// 上一次写进条上的颜色，用来避开无谓的重写。见 `refreshTheme()`。
    private var appliedBarColor: CGColor?

    static let iconSize = CGSize(width: 9, height: 10)
    private static let barWidth: CGFloat = 2
    private static let period: CFTimeInterval = 0.62
    private static let minScale: CGFloat = 0.34
    /// 音量 0 时的峰值高度。安静时也别缩成一条线。
    private static let peakFloor: CGFloat = 0.5
    private static let holdSeconds: TimeInterval = 0.4
    /// 常态那枚麦克风的不透明度。见 `micOn`：它得退到背景里。
    private static let micOnAlpha: CGFloat = 0.45
    /// 三根条的相位错开，不然是一起上下的一整块。
    private static let phases: [CFTimeInterval] = [0, 0.45, 0.22]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for bar in bars {
            bar.cornerRadius = Self.barWidth / 2
            bar.isHidden = true
            layer.addSublayer(bar)
        }
        /*
         两枚图标**走同一条装配路径**，不各写一遍。

         上一版就是各写一遍，而 `micOn` 那一份只写了一半——声明了、布局了、
         也在 apply 里 show/hide 了，唯独漏掉 `image` 与 `addSubview`。
         编译过、测试过（Kit 的 UIKit 用例在 macOS 上根本不执行），
         真机上就是「用户名右边一片留白」。写成一个循环之后，漏一半这件事做不到了。
        */
        for (view, icon, alpha) in [
            (micSlash, IMKitIcon.micSlash, CGFloat(1)),
            (micOn, IMKitIcon.mic, Self.micOnAlpha),
        ] {
            view.image = icon.image(pointSize: 9)
            view.contentMode = .center
            view.alpha = alpha
            view.isHidden = true
            view.frame = CGRect(origin: .zero, size: Self.iconSize)
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var intrinsicContentSize: CGSize { Self.iconSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        micSlash.frame = bounds
        micOn.frame = bounds
        let gap = (bounds.width - Self.barWidth * CGFloat(bars.count)) / CGFloat(bars.count - 1)
        for (index, bar) in bars.enumerated() {
            bar.frame = CGRect(x: CGFloat(index) * (Self.barWidth + gap), y: 0,
                               width: Self.barWidth, height: bounds.height)
        }
    }

    /**
     设置状态。`speaking` 与 `muted` **互斥**——静音的人不可能在说话，静音优先。

     - Parameter volume: 0~100，服务端给的音量，映射到峰值高度。
     - Parameter showsSpeaking: 这一格要不要区分「在说话」。**本端那格传 false**——
       自己在不在说话自己知道，只需要表达麦克风开关（2026-09-09 拍板）。
     */
    func apply(speaking: Bool, muted: Bool, volume: Int, showsSpeaking: Bool = true) {
        refreshTheme()
        if muted {
            quietWork?.cancel(); quietWork = nil
            stopBars()
            micOn.isHidden = true
            micSlash.isHidden = false
            return
        }
        micSlash.isHidden = true
        if speaking && showsSpeaking {
            quietWork?.cancel(); quietWork = nil
            micOn.isHidden = true
            startBars(volume: volume)
            return
        }
        // 从「说话」退出来才拖一拍；本来就没在说话就直接显示常态那枚。
        guard isAnimating, quietWork == nil else {
            micOn.isHidden = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.quietWork = nil
            self?.stopBars()
            self?.micOn.isHidden = false // 拖拍到点，换回常态那枚
        }
        quietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: work)
    }

    /**
     取色**放在每次 apply 里，不放在 init**。

     `IMKitTheme.current` 是个可写的全局，宿主随时能换一套配色；而 `CALayer.backgroundColor`
     要的是 `CGColor`——一个已经定死的值，不像 `UIColor` 那样会自己跟着走。
     在 init 里取一次的话，构造之后再改主题的宿主拿到的永远是旧的绿
     （旧代码是在 `apply` 里读 `IMKitTheme.current` 的，换主题一直是生效的，别把它丢了）。

     只在真的变了才写：这个方法 300ms 就会被调一次，而给 `CALayer` 赋色会触发一次
     隐式动画，每次都写等于让三根条一直在做多余的颜色过渡。
     */
    private func refreshTheme() {
        let theme = IMKitTheme.current
        micSlash.tintColor = theme.mutedBadge
        micOn.tintColor = theme.primaryText
        let color = theme.speakingBorder.cgColor
        if let applied = appliedBarColor, applied == color { return }
        appliedBarColor = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.backgroundColor = color }
        CATransaction.commit()
    }

    private func startBars(volume: Int) {
        let peak = Self.peakFloor + (1 - Self.peakFloor) * CGFloat(min(max(volume, 0), 100)) / 100
        for bar in bars { bar.isHidden = false }

        // 系统开了「减弱动态效果」：静止显示，不做动画（无障碍规范）。
        guard !UIAccessibility.isReduceMotionEnabled else {
            for (index, bar) in bars.enumerated() {
                bar.removeAllAnimations()
                bar.transform = CATransform3DMakeScale(1, index == 1 ? peak : peak * 0.7, 1)
            }
            isAnimating = true
            return
        }
        /*
         **已经在动了就什么都不做。**

         `room.active_speakers` 是 300ms 一次（协议 §3.5），而 `retarget` 会
         `removeAllAnimations()` 再重新 add——那等于每秒把三根条从固定相位强行归零三次，
         看上去是「一顿一顿地抖」，正是这个分支要避免的。

         峰值变化只影响振幅，不值得为它打断动画：条高本来就在跳，
         幅度差个几个百分点没人看得出来，而每 300ms 卡一下所有人都看得出来。
         下一次真正的起停（`stopBars` 之后再 `startBars`）会带上新的峰值。
        */
        guard !isAnimating else { return }
        for (index, bar) in bars.enumerated() { retarget(bar, index: index, peak: peak) }
        isAnimating = true
    }

    private func retarget(_ bar: CALayer, index: Int, peak: CGFloat) {
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = Self.minScale * peak
        animation.toValue = peak
        animation.duration = Self.period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timeOffset = Self.phases[index] * Self.period
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.removeAllAnimations()
        bar.add(animation, forKey: "talk")
    }

    private func stopBars() {
        isAnimating = false
        for bar in bars {
            bar.removeAllAnimations()
            bar.transform = CATransform3DIdentity
            bar.isHidden = true
        }
    }
}
#endif
