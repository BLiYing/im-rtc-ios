import Foundation

/*
 「在这个状态下结束这通电话」的**唯一一张表**（§5.1）。

 原先四处各写一份：宿主调 reject / cancel / hangup（`reduceAct`）、强制收场挑结束帧（`IMEngineMachine.endFrames`）、
 本地已经 idle 时迟到帧补发（`handleLateFrame`，以及 invite.ok 回来补发挂着的 cancel）、
 帧循环判断「哪些帧失败了也要本地收场」（`IMFrameLoop.exitFrames`）。
 哪份漏改一处，挂断键和红键看门狗发的就不是同一帧。现在都查这里；
 与 `call_fsm.json` 的逐条对照见 `CallExitTableTests`。
 */

/// IMCallExit 是某个通话状态下的结束方式。
struct IMCallExit: Equatable, Sendable {
    /// 宿主在这个状态下该调的退出方法（`reduceAct` 的 op）。换了状态调就是本地 2005。
    /// `accepting` 没有：接听在飞时宿主调不了任何退出方法，只有强制收场能收。
    let op: String?
    /// 按顺序发的结束帧，都只带 `call_id`。
    let frameTypes: [String]
    /// 本地收场时写的结束原因（强制收场按状态挑原因时用）。
    let reason: IMCallEndReason

    /**
     of 查表。`idle` 没有可结束的，返回 nil。

     - `accepting` 发 **reject + hangup 两帧**：accept 有没有在服务端落地，本端不知道。
       还在响铃就是 reject 生效（随后那条 hangup 被拒，无害）；已经接起来就是 hangup 生效。
     */
    static func of(_ state: IMCallState) -> IMCallExit? {
        switch state {
        case .idle:
            return nil
        case .inviting:
            return IMCallExit(op: "cancel", frameTypes: [IMFrameType.callCancel], reason: .cancel)
        case .ringing:
            return IMCallExit(op: "reject", frameTypes: [IMFrameType.callReject], reason: .reject)
        case .accepting:
            return IMCallExit(op: nil, frameTypes: [IMFrameType.callReject, IMFrameType.callHangup], reason: .hangup)
        case .connecting, .connected:
            return IMCallExit(op: "hangup", frameTypes: [IMFrameType.callHangup], reason: .hangup)
        }
    }

    /**
     serverState 是 idle 下迟到的这一帧说明的「服务端那边这通电话停在哪」，没有就是 nil（照旧丢弃）。

     - `call.invite.ok`：邀请在服务端落地了，被叫正在响铃——按 `inviting` 收（cancel）。
     - `call.connected`：有人已经接起来了（cancel 来不及，或本端是被叫、accept 已落地）——按 `connected` 收（hangup）。
     */
    static func serverState(afterLate type: String) -> IMCallState? {
        switch type {
        case IMEnvelope.okType(IMFrameType.callInvite): return .inviting
        case IMFrameType.callConnected: return .connected
        default: return nil
        }
    }

    /// allFrameTypes 是表里出现过的所有结束帧：这些帧失败了也要本地收场（ACTION_RESULT_DESIGN D2）。
    static let allFrameTypes: Set<String> = Set(
        [IMCallState.inviting, .ringing, .accepting, .connecting, .connected]
            .compactMap { of($0) }
            .flatMap(\.frameTypes))

    /// frames 把结束帧填上 `call_id`。
    func frames(callID: String) -> [IMOutgoingFrame] {
        frameTypes.map { IMOutgoingFrame($0, ["call_id": .string(callID)]) }
    }
}
