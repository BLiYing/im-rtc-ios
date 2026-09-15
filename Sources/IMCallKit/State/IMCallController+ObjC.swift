import Foundation

/*
 纯 ObjC 宿主想自画一点辅助 UI（例如自己的小状态条）时用得到的东西。拆成独立文件是
 体量红线（CONVENTIONS §2）：`IMCallController.swift` 已经逼近 600 行。

 # 为什么不整体桥 `IMCallViewState`

 `IMCallViewState` 是 Swift struct，字段里有 `IMCallPhase`（带 `String` rawValue 的 enum，
 ObjC 认的 `@objc enum` 只能是 `Int` 底层）、`[IMParticipant]`（Swift struct 数组）——
 逐字段桥一遍等于在 Kit 里再维护一份「ObjC 版状态机」，改一个字段两处都要改，
 CONVENTIONS §1 明令禁止的「私开一条通道」换了个方向重犯。

 这里只挑宿主真会问的几个标量（阶段 / 是否群聊 / call_id / 是否群通话 / 是否收进小窗 /
 媒体类型 / 1v1 对端 uid），够自画辅助 UI 用；要更细的字段，ObjC 宿主目前只能用 Kit
 整套 UI（`IMCallKit.start()`），或者说明缺什么再回来补这一份查询表。
 */

/// ObjC 友好的通话阶段镜像。**与 `IMCallPhase` 一一对应，但不改 `IMCallPhase` 本身**——
/// 那是 Swift 侧现有 API 的一部分（`String` 底层），改成 `@objc enum ... : Int` 会破坏
/// 现有 Swift 调用方与测试对它做字符串比较 / `Codable` 的假设。两份类型各司其职。
@objc public enum IMCallKitPhase: Int {
    case idle
    /// 收到来电，还没决定。
    case incoming
    /// 已拨出，等对方响应。
    case outgoing
    /// 对方接了，媒体还没通。
    case connecting
    /// 通话中。
    case active
    /// 已结束（纯展示态）。
    case ended
}

extension IMCallPhase {
    var objcValue: IMCallKitPhase {
        switch self {
        case .idle: return .idle
        case .incoming: return .incoming
        case .outgoing: return .outgoing
        case .connecting: return .connecting
        case .active: return .active
        case .ended: return .ended
        }
    }
}

extension IMCallController {
    /// 当前界面阶段（ObjC 友好镜像，见 `IMCallKitPhase`）。
    @objc public var objcPhase: IMCallKitPhase { state.phase.objcValue }

    /// 是否群通话。
    @objc public var isGroupCall: Bool { state.isGroup }

    /// 当前 call_id，空串 = 没有进行中的通话。
    @objc public var currentCallID: String { state.callID }

    /// 是否已收进悬浮小窗。
    @objc public var isMinimized: Bool { state.isMinimized }

    /// 当前媒体类型（`"audio"` / `"video"`）。
    @objc public var currentMediaType: String { state.mediaType }

    /// 1v1 对端 uid；群通话为空串。
    @objc public var peerUID: String { state.peerUID }
}

/**
 ObjC 可用的状态变化通知。

 **为什么要加**：现有的 `IMCallControllerObserver`（`addObserver(_:)`）是非 `@objc` 的
 Swift 协议——`IMCallViewState` 本身不是 ObjC 能表达的类型，协议签名带着它，ObjC 类型
 天生实现不了。没有任何通知的话，ObjC 宿主只能自己起个定时器轮询上面那组 `@objc` 属性，
 猜「什么时候该问一次」；挂断、对端把本端踢出通话之类由 Engine 回调驱动的变化就会被漏掉
 或者延迟一个轮询周期才发现。这是「有必要才加」里的必要项。

 **只传 controller 自身，不带状态快照**：宿主随后读 `objcPhase` / `isGroupCall` 等属性即可，
 不需要在这里再维护第二份「ObjC 版 `IMCallViewState`」——那正是上面那条注释想避免的重复。

 只提供 delegate 形式，没有另配一份 block 形式：CONVENTIONS §4「回调同时提供 delegate 与
 block 两种形式」针对的是 Engine 那张对外回调总表（§7.5，宿主必接的信令/媒体事件）；
 这里是 Kit 内部一个「要不要都行」的轻量通知，块形式需要额外一个 token 对象管生命周期，
 目前没有真实宿主提出这个需求，先不加，需要时再补。
 */
@objc public protocol IMCallControllerStateObserver: AnyObject {
    func callControllerDidUpdateState(_ controller: IMCallController)
}

extension IMCallController {
    /// 注册一个 ObjC 可用的状态观察者。与 `addObserver(_:)`（Swift-only）走同一次 `broadcast()`，
    /// 只是分开两张表——两边互不知道对方的存在，谁也不会漏收到通知。
    @objc public func addStateObserver(_ observer: IMCallControllerStateObserver) {
        objcObservers.add(observer)
    }

    @objc public func removeStateObserver(_ observer: IMCallControllerStateObserver) {
        objcObservers.remove(observer)
    }
}
