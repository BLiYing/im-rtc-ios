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

/// Kit 的版本号。与 Engine 同步升，**四端共享大版本**（协议不兼容才升大版本）。
public let IMCallKitVersion = "0.0.1"

/// Kit 的配置。随界面落地逐步长出来。
@objc public final class IMCallKitConfig: NSObject {
    /// 通话页固定深色、不随宿主主题（对齐草图 §01；FaceTime / Telegram 同做法）。
    @objc public var forcesDarkAppearance: Bool = true

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
        super.init()
    }

    /// 状态中枢。宿主想自己画一部分界面时也能读它。
    public let controller: IMCallController

    #if canImport(UIKit)
    private lazy var callWindow = IMCallWindow(controller: controller)
    #endif

    /**
     start 接管来电弹屏、通话页、九宫格、悬浮窗（草图 §01 的用法 B）。

     一行调用即可。**界面的出现与消失由状态驱动**——宿主只管调
     `controller.placeCall` / `joinMeeting`，Kit 自己接住剩下的。
     */
    @objc public func start() {
        IMRTCLog.info("[Kit] 启动", ["version": IMCallKitVersion])
        #if canImport(UIKit)
        _ = callWindow // 让它订阅上 controller；之后由状态驱动显示与收起
        #endif
    }
}
