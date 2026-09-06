#if canImport(UIKit)
import UIKit

/*
 Kit 的配色与尺寸 —— 设计稿《通话界面规范》§02–§04、§07 的落点。
 **所有色值集中在这里，禁止在组件里硬编码**（CONVENTIONS §8）。字段名与 Web 的 `theme.ts`
 逐条对应（`overlayBackground ↔ overlay`、`controlBackground ↔ ctlIdle`…），四端同值。

 # 通话页固定深色、不随宿主主题

 对齐草图 §03，FaceTime / Telegram 同做法。理由是通话页几乎总是叠在视频画面上，
 浅色主题下白底会把画面衬得发灰，而且宿主切主题时通话页跟着闪一下很出戏。

 想换皮肤就整个替换 `IMKitTheme.current`——但**样式不是本产品的卖点**，别在这上面加抽象。
 */
public struct IMKitTheme: Sendable {
    // MARK: 颜色（规范 §02 的 11 个语义色）

    /// 全屏遮罩底色 #121418。
    public var overlayBackground = UIColor(red: 0x12 / 255, green: 0x14 / 255, blue: 0x18 / 255, alpha: 1)
    /// 语音通话页的径向渐变：#2A3350 → #0F1117。视频页被画面盖住，用不到。
    public var callGradientTop = UIColor(red: 0x2A / 255, green: 0x33 / 255, blue: 0x50 / 255, alpha: 1)
    public var callGradientBottom = UIColor(red: 0x0F / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1)
    public var primaryText = UIColor.white
    public var secondaryText = UIColor(white: 1, alpha: 0.7)
    /// 头像兜底底色 #2B3038（没算出渐变时）。
    public var avatarBackground = UIColor(red: 0x2B / 255, green: 0x30 / 255, blue: 0x38 / 255, alpha: 1)
    /// 格子底色（没有画面时露出来的那层）。
    public var tileBackground = UIColor.black
    /// 控制按钮的常态（半透明白 14%）。
    public var controlBackground = UIColor(white: 1, alpha: 0.14)
    /// **开启态白底黑字**（规范 §06：反白，不是变蓝）。
    public var controlActiveBackground = UIColor.white
    public var controlActiveText = UIColor(red: 0x12 / 255, green: 0x14 / 255, blue: 0x18 / 255, alpha: 1)
    /// 挂断恒红 #E5484D、接听恒绿 #3DDC84——**不随宿主主题**。
    public var danger = UIColor(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1)
    public var accept = UIColor(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255, alpha: 1)
    public var acceptText = UIColor(red: 0x08 / 255, green: 0x21 / 255, blue: 0x0F / 255, alpha: 1)
    /// 正在说话时格子的描边。**绿色在通话页只有接听与发言两个含义**，别拿去当别的。
    public var speakingBorder = UIColor(red: 0x3D / 255, green: 0xDC / 255, blue: 0x84 / 255, alpha: 1)
    /// 「网络不佳」「正在重连…」的横幅与角标 #F5A623。
    public var warning = UIColor(red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255, alpha: 1)
    /// 格子上「对方已静音」角标的图标色 #FFB4AE。
    public var mutedBadge = UIColor(red: 0xFF / 255, green: 0xB4 / 255, blue: 0xAE / 255, alpha: 1)
    /// 来电横幅 / 提示卡 / 选人页的底 #1E2330。
    public var banner = UIColor(red: 0x1E / 255, green: 0x23 / 255, blue: 0x30 / 255, alpha: 1)
    /// 格子上名字标签、角标的黑底 55%。
    public var scrim = UIColor(white: 0, alpha: 0.55)

    // MARK: 尺寸（规范 §04）

    /// 控制按钮直径 56；挂断 / 接听 64；第二排的次级动作 44。
    public var controlSize: CGFloat = 56
    public var controlSizeBig: CGFloat = 64
    public var controlSizeSmall: CGFloat = 44
    public var iconPointSize: CGFloat = 22
    public var iconPointSizeBig: CGFloat = 26
    public var iconPointSizeSmall: CGFloat = 18
    /// 1v1 大头像。
    public var avatarLarge: CGFloat = 96
    public var tileGap: CGFloat = 8
    public var tileCornerRadius: CGFloat = 10
    public var speakingOutline: CGFloat = 2.5
    public var pipCornerRadius: CGFloat = 12
    /// 悬浮球：语音 56 圆；视频 90×120 带缩略画面。
    public var bubbleSize: CGFloat = 56
    public var bubbleVideoSize = CGSize(width: 90, height: 120)
    /// 顶部标题区与底部控制条的固定高度：中间区域靠约束吃掉剩余空间。
    public var headerHeight: CGFloat = 64
    public var controlsHeight: CGFloat = 96

    // MARK: 动效（规范 §07）

    public var pressDuration: TimeInterval = 0.12
    public var snapDuration: TimeInterval = 0.25
    public var swapDuration: TimeInterval = 0.26
    public var fadeDuration: TimeInterval = 0.2
    /// 视频通话里控制条多久后自动隐藏。
    public var autoHideDelay: TimeInterval = 3
    /// 小窗要长按这么久才进拖动态。
    public var longPressDelay: TimeInterval = 0.35
    /// 邀请中的占位格「已拒绝 / 未接听」停多久再移除。
    public var settledHold: TimeInterval = IMSettledHoldSeconds
    /// 「对方网络不佳」横幅多久后收起成角标。
    public var networkBannerHold: TimeInterval = 2

    public init() {}

    /// 当前主题。宿主想换皮肤就整个替换它。
    public nonisolated(unsafe) static var current = IMKitTheme()

    /**
     九个头像渐变（规范 §02），取哪一个见 `imAvatarIndex`。每项是 (起, 止) 两色，160° 方向。
     */
    public static let avatarGradients: [(UIColor, UIColor)] = [
        (rgb(0x9E7BF0), rgb(0x6E52D6)), (rgb(0x3AA0FF), rgb(0x0A6BE0)), (rgb(0x4CD268), rgb(0x28B14A)),
        (rgb(0xFBB040), rgb(0xF5872B)), (rgb(0xFF7AA8), rgb(0xE0559E)), (rgb(0x5ED3D0), rgb(0x2AA6A3)),
        (rgb(0xB0B8C8), rgb(0x7E8797)), (rgb(0xF08A5D), rgb(0xC94F3B)), (rgb(0x7C9CF0), rgb(0x4C6BD6)),
    ]

    /// avatarGradient 返回某个 uid 的头像渐变两色。
    public static func avatarGradient(for uid: String) -> (UIColor, UIColor) {
        avatarGradients[imAvatarIndex(uid)]
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 图标名 —— 与设计稿 §05 的 SF Symbols 对照表一致。**Kit 里只从这里取符号名**，不散写字符串。
public enum IMKitIcon: String {
    case mic = "mic.fill"
    case micSlash = "mic.slash.fill"
    case video = "video.fill"
    case videoSlash = "video.slash.fill"
    case phone = "phone.fill"
    case phoneDown = "phone.down.fill"
    case xmark = "xmark"
    case minimize = "arrow.down.right.and.arrow.up.left"
    case expand = "arrow.up.left.and.arrow.down.right"
    case speaker = "speaker.wave.2.fill"
    case speakerSlash = "speaker.slash.fill"
    case cameraFlip = "arrow.triangle.2.circlepath.camera"
    case personAdd = "person.badge.plus"
    case plus = "plus"
    case chevronDown = "chevron.down"
    case more = "ellipsis"
    case screenShare = "rectangle.on.rectangle"
    case grid = "square.grid.2x2"
    case settings = "gearshape"

    /// image 取系统符号图。SF Symbols 是系统内置的矢量图标，**不用 emoji**（真机上会渲染成方框问号）。
    public func image(pointSize: CGFloat = IMKitTheme.current.iconPointSize,
                      weight: UIImage.SymbolWeight = .medium) -> UIImage? {
        UIImage(systemName: rawValue,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }
}

/// imMakeAvatarGradientLayer 造一个 160° 方向的渐变层，给头像盘用。
public func imMakeAvatarGradientLayer(for uid: String) -> CAGradientLayer {
    let (top, bottom) = IMKitTheme.avatarGradient(for: uid)
    let layer = CAGradientLayer()
    layer.colors = [top.cgColor, bottom.cgColor]
    layer.startPoint = CGPoint(x: 0.15, y: 0)
    layer.endPoint = CGPoint(x: 0.85, y: 1)
    return layer
}
#endif
