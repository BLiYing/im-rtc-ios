#if canImport(UIKit)
import UIKit

/*
 Kit 的配色与尺寸。**所有色值集中在这里，禁止在组件里硬编码**（CONVENTIONS §8）。

 # 通话页固定深色、不随宿主主题

 对齐草图 §03，FaceTime / Telegram 同做法。理由是通话页几乎总是叠在视频画面上，
 浅色主题下白底会把画面衬得发灰，而且宿主切主题时通话页跟着闪一下很出戏。

 想换皮肤就整个替换 `IMKitTheme.current`——但**样式不是本产品的卖点**，
 别在这上面加抽象。
 */
public struct IMKitTheme: Sendable {
    /// 全屏遮罩底色。
    public var overlayBackground = UIColor(white: 0.07, alpha: 1)
    public var primaryText = UIColor.white
    public var secondaryText = UIColor(white: 1, alpha: 0.7)
    /// 头像底色。
    public var avatarBackground = UIColor(red: 0.17, green: 0.19, blue: 0.22, alpha: 1)
    /// 格子底色（没有画面时露出来的那层）。
    public var tileBackground = UIColor.black
    /// 控制按钮的常态（半透明白）。
    public var controlBackground = UIColor(white: 1, alpha: 0.14)
    /// **开启态白底黑字**（草图 §03：静音/扬声器打开时的样子）。
    public var controlActiveBackground = UIColor.white
    public var controlActiveText = UIColor(white: 0.07, alpha: 1)
    /// 挂断恒红、接听恒绿——**不随宿主主题**。
    public var danger = UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)
    public var accept = UIColor(red: 0.24, green: 0.86, blue: 0.52, alpha: 1)
    /// 正在说话时格子的描边。
    public var speakingBorder = UIColor(red: 0.24, green: 0.86, blue: 0.52, alpha: 1)

    /// 控制按钮直径。草图 §03 定的 56pt。
    public var controlSize: CGFloat = 56
    /// 格子间距。
    public var tileGap: CGFloat = 8
    public var tileCornerRadius: CGFloat = 10

    public init() {}

    /// 当前主题。宿主想换皮肤就整个替换它。
    public nonisolated(unsafe) static var current = IMKitTheme()
}
#endif
