import Foundation

/*
 视图模型上的**判据**：红按钮该发哪个动作、要不要给摄像头按钮、要不要给加人入口、用哪种版式。
 全是纯函数，配 `CallViewStateTests`。与 Web 的 `callView.ts` / `ActiveCall.tsx` 的同名函数逐条对应。
 */

/// 红按钮该发出的那个动作。
public enum IMEndAction: String, Sendable {
    case leaveRoom, cancel, reject, hangup
}

/**
 红按钮在**四种场合是四个不同的动作**，分辨这件事是 Kit 的责任——让调用方去分辨，迟早有人分辨错。
 最容易错的那一条没法靠点界面发现：会议房里根本没有 call，发 hangup 会被状态机本地拒成 2005。
 */
public func imEndAction(for state: IMCallViewState) -> IMEndAction {
    if state.isMeeting { return .leaveRoom }
    switch state.phase {
    case .incoming: return .reject
    case .outgoing: return .cancel
    default:        return .hangup
    }
}

/**
 进这一通电话时摄像头开不开。

 **1v1 视频默认开**：那一屏的产品意图就是看见对方，进来一片头像盘是错的。
 **群通话默认关**（2026-09-09）：群里进去时没人在出镜，摄像头这件事该由用户自己点开。
 真正要紧的是它的连带后果——摄像头权限从「发起群通话的前置条件」降级成
 「按下那颗按钮时才要的东西」，于是**没有摄像头权限也能发起和参加群通话**
 （见 `imPermissionDevicesForPlacing`）。人多的时候还顺带省掉一路上行。

 **会议房不走这里**（`meetingJoined` 里仍是默认开）：同样的道理适用，但会议房刚按
 「默认开」在真机上验过，改它要重验，留到下一轮定。

 规范见《界面规范》§04 末尾与《交互流程》§01。与 Android 的
 `IMCallViewReducer.defaultCameraOn` 是同一条判据。
 */
public func imDefaultCameraOn(mediaType: String, isGroup: Bool) -> Bool {
    mediaType == "video" && !isGroup
}

/// 红键按下后，等服务端把这一屏收掉的最长时间；到点还在原地就本地收场（`IMCallController.end`）。
///
/// 3 秒是「慢网也该回来了」与「用户还没开始怀疑手机坏了」之间的那个数：
/// 正常路径上 `call.hangup.ok` 与 `call.ended` 都在百毫秒级。与 Android 的
/// `IMRedButtonWatchdog.DEFAULT_TIMEOUT_MS` 是同一个数。
public let IMEndWatchdogSeconds: TimeInterval = 3

/// 本地收场时写哪个结束原因。**照红键实际发出去的那个动作写**，不写 "network"：
/// 复现出来的那一次网络是好的（是权限门没落定、帧压根没发），
/// 屏幕上写「网络中断」是在冤枉网络，还会按 `imEndedHoldSeconds` 多停 1.5 秒。
public func imEndWatchdogReason(for action: IMEndAction) -> String {
    switch action {
    case .cancel: return "cancel"
    case .reject: return "reject"
    case .hangup, .leaveRoom: return "hangup"
    }
}

/**
 通话中该不该显示「摄像头」按钮。**只看 media_type，不看本端摄像头开没开。**
 语音通话里不给：协议上没有「转视频」这回事（拍板 §11-10）。视频通话里关了摄像头按钮仍要有。
 */
public func imShowsCameraButton(for state: IMCallViewState) -> Bool {
    state.mediaType == "video"
}

/// 群通话上限（拍板 §11-1，含本端正好 3×3）。
public let IMMaxCallParticipants = 9

/// 邀请中的占位格「已拒绝 / 未接听」停多久再移除（规范 §07）。放这里而不是 IMKitTheme：controller 在 macOS 上也要编。
public let IMSettledHoldSeconds: TimeInterval = 2

/// 一次性提示（「通话已满员」「对方已拒接」）停多久自己撤掉（规范 §08）。
public let IMHintHoldSeconds: TimeInterval = 3

/**
 imCanShowInvite 决定要不要给「添加成员」入口（交互稿 §05）。

 条件缺一不可：是群通话（会议房没有 call，走的是别的加人机制）、已接通、房间没满（含本端 9 人）。
 **不看主叫被叫**：通话里的任何人都能加人（2026-09-15 起）；还在响铃的人阶段不对，自然没有入口。
 */
public func imCanShowInvite(for state: IMCallViewState) -> Bool {
    state.isGroup && !state.isMeeting && state.canInvite
        && state.participants.count + 1 < IMMaxCallParticipants
        && (state.phase == .active || state.phase == .connecting)
}

/// imInviteSlotsLeft 是还能加几个人（选人页顶部「还能加 N 人」）。
public func imInviteSlotsLeft(for state: IMCallViewState) -> Int {
    max(IMMaxCallParticipants - 1 - state.participants.count, 0)
}

/**
 imJoinCallAllowed 报告此刻能不能开始「主动加入」：**只有界面空闲、或停在上一通的结束画面时才行**。

 已经在一场里时 Engine 只会本地回 2005、不会有 `callDidEnd`；而加入流程第一步就把界面切成「接通中…」——
 放行的话，正在进行的那通电话的界面被盖掉、再也收不回来（2026-09-15 代码审查，三端同一个坑）。
 */
public func imJoinCallAllowed(from phase: IMCallPhase) -> Bool {
    phase == .idle || phase == .ended
}

/// 通话主界面的三种版式（规范 §03 / §04）。
public enum IMCallLayout: String, Sendable {
    /// 语音通话、拨出中：96 头像 + 名字 + 状态。
    case audio
    /// 1v1 视频通话中：远端全屏 + 本端小窗。
    case video
    /// 群通话 / 会议：九宫格。
    case grid
}

/**
 imPickLayout 决定此刻用哪种版式。

 **接通后的 1v1 视频恒为 video 版式**，哪怕两边都关着摄像头——那时全屏格与小窗各显示一个
 头像盘。原先是「都没画面就退回语音版式」，实测下来不对：小窗会整个消失，
 用户以为通话断了，而且关掉摄像头之后就再也点不到「互换」。没画面是格子的事，不是版式的事。

 拨出中与来电页仍用语音版式：那时对端画面不存在，本端预览叠在右上角（草图 §03-E）。
 */
public func imPickLayout(for state: IMCallViewState) -> IMCallLayout {
    if state.isGroup || state.isMeeting { return .grid }
    if state.mediaType != "video" { return .audio }
    if state.phase == .outgoing || state.phase == .incoming { return .audio }
    return .video
}

/// imSettledText 是占位格上终局的人话（规范 §08）。
public func imSettledText(_ outcome: IMSettledOutcome) -> String {
    switch outcome {
    case .none:     return ""
    case .rejected: return "已拒绝"
    case .noAnswer: return "未接听"
    case .offline:  return "对方不在线"
    }
}

/**
 结束原因的人话。**结束画面必须说清为什么**——只写「通话结束」然后 1.5 秒消失，
 用户根本不知道是对方拒了、忙线、还是压根不在线。未知值兜底成「已结束」，**不显示原始英文**。
 与 Web 的 `endReasonText` / Android 的 `endReasonText` **逐字对齐**——三端漏一条，
 同一个结局在两台设备上就会写着不一样的话。
 */
public func imEndReasonText(_ reason: String, role: String, durationSec: Int) -> String {
    switch reason {
    case "hangup":
        return durationSec > 0 ? "通话结束 · \(imFormatDuration(durationSec))" : "通话结束"
    case "cancel":
        return role == "caller" ? "已取消" : "对方已取消"
    case "reject":
        return role == "caller" ? "对方已拒接" : "已拒接"
    case "busy":
        return "对方忙线中"
    case "no_answer":
        return role == "caller" ? "对方无人接听" : "未接来电"
    case "offline":
        return "对方当前不在线"
    case "network":
        return "网络中断"
    case "answered_elsewhere":
        return "已在其他设备接听"
    case "rejected_elsewhere":
        return "已在其他设备拒绝"
    case "room_closed":
        return "房间已解散"
    case "kicked":
        return "已被移出"
    /*
     `join_denied` 不是协议里的 reason（协议 §6 那张表没有它）——它是 Kit 本地的伪原因，
     只在 `IMCallController.joinCall(_:)` 被拒（任何码）时使用，从不上线路、从不来自服务端。
     真实的服务端结局折到这条分支之外那个 `default`，与四端共用的原因表不冲突。
    */
    case "join_denied":
        return "无法加入该通话"
    default:
        return "已结束"
    }
}

/// 结束画面停留多久。**说不清原因的那几种要停久一点**。与 Web 的 `endedHoldMs` 同一张表。
public func imEndedHoldSeconds(_ reason: String) -> TimeInterval {
    switch reason {
    case "hangup", "cancel": return 1.5
    default: return 3.0
    }
}

/// imNetworkText 是网络质量的人话（协议 §3.5 的表：1~2 好、3~4 一般、5 很差、6 重连）。
public func imNetworkText(level: Int) -> String {
    switch level {
    case ...0:  return ""
    case 1...2: return "网络良好"
    case 3...4: return "网络一般"
    case 5:     return "网络很差"
    default:    return "正在重连…"
    }
}

/// imNetworkBarsLit：三根柱子亮几根。1~2 三根、3~4 两根、5~6 一根；0 不画。
public func imNetworkBarsLit(level: Int) -> Int {
    switch level {
    case ...0:  return 0
    case 1...2: return 3
    case 3...4: return 2
    default:    return 1
    }
}

/// imIsNetworkPoor：要不要出「对方网络不佳」的提示（3 以上）。
public func imIsNetworkPoor(level: Int) -> Bool { level >= 3 }

/// 此刻该放哪种铃声（还是不放）。三端同名同值，逐字一致——见 `ringtoneFor`。
public enum IMRingtoneKind: String, Sendable {
    case none, incoming, ringback
}

/**
 ringtoneFor 决定此刻该不该放铃声、放哪一种（播放动作在 `IMCallController+Ringtone.swift`）。

 **纯函数，不带 UIKit**：与本文件其余判据放在一起，才能在 macOS 上 `swift test` 覆盖到——
 Kit 的 UI/播放器代码全包在 `#if canImport(UIKit)` 里，这台机器编不到那一半。

 `muted` 优先于一切：宿主/用户静音了什么都不放。会议没有振铃（`meetingJoined` 直接进
 `connecting`，从没经过 `incoming`/`outgoing`），`isMeeting` 这里仍显式判一道，意图更明确、
 不依赖「反正 phase 也到不了那两档」这种隐含前提。

 **停铃按 phase 收敛，不按事件特判**：`.callEnd` 在 `phase == .incoming` 时直接重置回
 `idle`、不经过 `.ended`（`IMCallViewState.swift` 的 `reduceCallView`），二者 default 分支
 都落在 `.none`，同一条规则天然盖住两条路径。
 */
public func ringtoneFor(_ state: IMCallViewState, muted: Bool) -> IMRingtoneKind {
    if muted { return .none }
    if state.isMeeting { return .none }
    switch state.phase {
    case .incoming: return .incoming
    case .outgoing: return .ringback
    default: return .none
    }
}

/// 来电振动的间隔：系统振动一下约 0.4 秒，停 1.6 秒再来，节奏接近系统来电。
public let IMIncomingVibrationIntervalSeconds: TimeInterval = 2

/**
 imShouldVibrate 决定此刻该不该振动（播放动作在 `IMCallController+Ringtone.swift`）。

 只在**来电响铃**时振（交互稿 §F「铃声 + 震动」）；拨出中的回铃不振，会议没有振铃。
 **与 `ringtoneMuted` 无关**：静音铃声是「别出声」，振动是另一个开关（`IMCallKitConfig.incomingVibration`）——
 手机开着静音模式时，振动恰恰是用户唯一能察觉来电的方式。
 振动只在 iOS 做：Android 要宿主多声明 `VIBRATE` 权限、Web 振不了，见 CLIENT_PARITY「来电铃声」一行。
 */
public func imShouldVibrate(_ state: IMCallViewState, enabled: Bool) -> Bool {
    enabled && !state.isMeeting && state.phase == .incoming
}

