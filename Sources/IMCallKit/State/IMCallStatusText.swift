import Foundation

/*
 通话页标题栏与状态行的文案。纯函数，从 `IMCallOverlayViewController` 里拎出来直接单测
 （macOS 上 `swift test` 也跑得到——VC 本身在 `#if canImport(UIKit)` 里）。
 */

/**
 标题：会议写**房号**，群通话写人数（含自己），1v1 写对方名字（走宿主解析器，解析不到才退回 uid）。

 会议不写人数：右上角那颗「👥 N」已经是人数的出处，标题再写一遍是同一个数字的第二处真相。
 房号才是这一屏里**要念给别人听**的那个东西（口头报号 / 点一下复制）。
 */
public func imCallTitle(_ state: IMCallViewState, resolver: IMProfileResolving? = nil) -> String {
    if state.isMeeting { return state.roomID.isEmpty ? "会议" : "会议 \(state.roomID)" }
    if state.isGroup { return "群通话 · \(state.participants.count + 1) 人" }
    return state.peerUID.isEmpty ? "通话" : imResolvedName(resolver, uid: state.peerUID, fallback: state.peerUID)
}

/// 状态行：一次性提示优先；通话中是时长（`now` 可注入，默认当前时间）。
public func imCallStatusLine(_ state: IMCallViewState, now: TimeInterval = Date().timeIntervalSince1970) -> String {
    if !state.hint.isEmpty { return state.hint }
    switch state.phase {
    case .incoming:   return state.mediaType == "video" ? "邀请你视频通话" : "邀请你语音通话"
    case .outgoing:   return "正在呼叫…"
    case .connecting: return state.isMeeting ? "正在进入会议…" : "接通中…"
    case .ended:
        // 时长用服务端给的那个（不变量 I8）。现算的话，没接通的通话 beganAt 是 0，
        // 算出来是一九七〇年到现在的秒数。
        return state.isMeeting ? "已离开会议"
            : imEndReasonText(state.endReason, role: state.role, durationSec: state.endedDurationSec)
    case .active:     return imFormatDuration(Int(now - state.beganAt))
    case .idle:       return ""
    }
}
