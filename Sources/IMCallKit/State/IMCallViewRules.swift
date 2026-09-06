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

 三个条件缺一不可：是群通话（会议房没有 call，走的是别的加人机制）、本端是主叫
 （协议 1407：非主叫发 `invite_more` 会被拒）、房间没满（含本端 9 人）。
 */
public func imCanShowInvite(for state: IMCallViewState) -> Bool {
    state.isGroup && !state.isMeeting && state.role == "caller" && state.canInvite
        && state.participants.count + 1 < IMMaxCallParticipants
        && (state.phase == .active || state.phase == .connecting)
}

/// imInviteSlotsLeft 是还能加几个人（选人页顶部「还能加 N 人」）。
public func imInviteSlotsLeft(for state: IMCallViewState) -> Int {
    max(IMMaxCallParticipants - 1 - state.participants.count, 0)
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
