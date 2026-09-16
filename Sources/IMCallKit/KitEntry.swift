#if canImport(UIKit)
import UIKit
#endif
import Foundation
import IMCallEngine

/*
 IMCallKit —— 整套通话界面。**目前只是骨架**：产品的两种集成方式从这里分岔。

 # 为什么空壳也要现在就立起来

 「两个 product」这件事必须从第一天就摆在 `Package.swift` 里，否则 Kit 落地时
 才会发现它已经用了 Engine 的内部符号——那时候再拆就是大手术。
 有了这个 target，**跨 module 的边界从现在起每次编译都在被检查**：
 Kit 只能看见 Engine 的 `public` 面，看不见任何 internal 的东西。

 # 它不是特权组件

 Kit 拿到的信息与「宿主自画 UI」完全一致——就是 `IMCallEngineDelegate` 那张表
 （设计文档 §7.5）。一旦某个界面需要 Engine 开私有口子，
 说明**那张表少了一项，该补表，不是开后门**。

 # 边界

 不做宿主业务界面：消息气泡、会话列表、「群里谁在通话」的横幅，都由宿主自己实现
 （CONVENTIONS §11）。Kit 只负责来电页/横幅、1v1 四态、九宫格、悬浮窗。
 */

/// Kit 的版本号。**就是 Engine 的版本号**（`IMCallEngineVersion`），不单独维护——
/// 两者同仓同发，分开写只会漂。五端共享大版本（协议不兼容才升大版本）。
public let IMCallKitVersion = IMCallEngineVersion

/// Kit 的配置。随界面落地逐步长出来。
@objc public final class IMCallKitConfig: NSObject {
    /// 通话页固定深色、不随宿主主题（对齐草图 §01；FaceTime / Telegram 同做法）。
    @objc public var forcesDarkAppearance: Bool = true
    /// 来电先出顶部横幅，点横幅再展开全屏（草图 §04）。关掉则直接全屏。
    @objc public var bannerFirst: Bool = true
    /// 允许收进悬浮球（草图 §04）。关掉则通话页没有「小窗」按钮。
    @objc public var floatingWindow: Bool = true
    /**
     群通话里「添加成员」的候选名单（静态兜底，保留兼容，交互稿 §05）。**名单是宿主给的**——
     Kit 不内置联系人系统（CONVENTIONS §11）。优先级见 `inviteMemberProvider`。
     */
    @objc public var inviteCandidates: [IMInviteCandidate] = []

    /**
     按通话向宿主要候选人的钩子（HOST_INTEGRATION_DESIGN §3.4，2026-09-15）——取代静态
     `inviteCandidates`，支持分页搜索、按群号区分名单。**强引用**：见 `IMCallController.inviteMemberProvider`。

     **取名单优先级**：宿主接管选人页（`presentInvitePicker`）> 这个 provider >
     静态 `inviteCandidates`（保留兼容）> 空态「没有可邀请的成员」。
     */
    @objc public var inviteMemberProvider: IMInviteMemberProvider?

    /// uid 输入框默认关，打开后只出现在候选名单为空的空态里，只给 Demo 用（§3.4）。
    @objc public var allowsManualUIDInput = false

    /// uid → 本机该显示的名字与头像（见 `IMProfileResolving`）。
    ///
    /// **不设就退化成显示 uid**，与没有这个钩子时行为一致。
    /// 宿主异步解析回来后调 `IMCallKit.reloadProfiles(_:)` 重画。
    ///
    @objc public weak var profileResolver: IMProfileResolving?

    /**
     来电铃声 / 回铃音（2026-09-16，交互稿「来电铃声 + 回铃音」）。**每次响铃/回铃前现读**，
     与 `bannerFirst` / `floatingWindow` 同一类——宿主运行时改了立刻生效，不是 init 时的快照
     （不同于 `inviteCandidates` 那种一次性名单）。`nil` = 用包内置的默认音（`Bundle.module`
     里的 `im_ringtone.mp3` / `im_ringback.mp3`）。播放逻辑见 `IMCallController+Ringtone.swift`。
     */
    @objc public var incomingRingtone: URL?
    /// 回铃音（拨出中）。同上。
    @objc public var ringbackTone: URL?
    /// 静音铃声/回铃音（不影响通话本身的音频）。默认关。
    @objc public var ringtoneMuted: Bool = false

    @objc public override init() {
        super.init()
    }
}

/**
 Kit 的入口。

 **界面挂在独立 window 层**，不入宿主导航栈——任何页面都能被来电覆盖
 （CONVENTIONS §8）。这也是 Demo 选 UIKit 生命周期的原因：
 建那个 window 要拿到 `UIWindowScene`，SceneDelegate 里直接就有。
 */
@objc public final class IMCallKit: NSObject {
    /// Kit 依赖的 Engine。**单向依赖**：Engine 绝不反向依赖 Kit（CONVENTIONS §1）。
    @objc public let engine: IMCallEngine
    @objc public let config: IMCallKitConfig

    @objc public init(engine: IMCallEngine, config: IMCallKitConfig = IMCallKitConfig()) {
        self.engine = engine
        self.config = config
        self.controller = IMCallController(engine: engine)
        self.controller.inviteCandidates = config.inviteCandidates
        self.controller.inviteMemberProvider = config.inviteMemberProvider
        self.controller.allowsManualUIDInput = config.allowsManualUIDInput
        self.controller.profileResolver = config.profileResolver
        // **存的是同一个 config 实例，不是拷贝字段**：铃声那三个字段要「现用现读」
        // （见 IMCallKitConfig 的注释），controller 里随时 `config.incomingRingtone` 都是最新值。
        self.controller.config = config
        super.init()
    }

    /// 状态中枢。宿主想自己画一部分界面时也能读它。
    @objc public let controller: IMCallController

    /**
     joinCall 主动加入一通正在进行的群通话（HOST_INTEGRATION_DESIGN §3.4）。

     进「接通中…」界面；被拒（1409 等）按错误码提示并收起——见
     `IMCallController.joinCall(_:)` 与 `IMCallController+Delegate.swift` 的
     `didFailWithError`。
     */
    @objc public func joinCall(_ callID: String) {
        controller.joinCall(callID)
    }

    #if canImport(UIKit)
    private lazy var callWindow = IMCallWindow(controller: controller, config: config)
    #endif

    /**
     start 接管来电弹屏、通话页、九宫格、悬浮窗（草图 §01 的用法 B）。

     一行调用即可。**界面的出现与消失由状态驱动**——宿主只管调
     `controller.placeCall` / `joinMeeting`，Kit 自己接住剩下的。
     */
    /// 宿主的身份解析回来了，重画用到这些 uid 的地方（见 `IMProfileResolving`）。
    @objc public func reloadProfiles(_ uids: [String]) {
        controller.reloadProfiles(uids)
    }

    @objc public func start() {
        IMRTCLog.info("[Kit] 启动", ["version": IMCallKitVersion])
        #if canImport(UIKit)
        _ = callWindow // 让它订阅上 controller；之后由状态驱动显示与收起
        #endif
    }
}

extension IMCallKit {
    /// Kit 版本号（= `IMCallKitVersion`）。全局常量 ObjC 看不见，所以门面上再挂一个
    /// （同 `IMCallEngine.sdkVersion` 的做法）。
    @objc public static var kitVersion: String { IMCallKitVersion }
}
