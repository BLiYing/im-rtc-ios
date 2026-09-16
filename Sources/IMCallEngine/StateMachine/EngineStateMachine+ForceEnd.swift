import Foundation

/*
 强制收场：红键按下去**等不到结束事件**时的出口（门面见 `IMCallEngine.forceEnd()`）。

 # 为什么 hangup 不够

 hangup 只发帧，状态由随后的 `call.ended` 推进——服务端才是裁决方（§5.1）。帧要是根本没发出去，
 这一场就永远收不掉：2026-09-13 14:54 frank 按了挂断，`call.hangup` 一帧没到服务端，
 Kit 的看门狗把界面收了，Engine 却还留在通话与房间里，别人一直看得见他，直到 14:58 整通结束。

 # 这里只算「该发什么、收成什么样」

 纯函数，与 `dropLostSession` 同一个形状：通话机、房间机一起归零，抛唯一的结束出口。
 **发帧由门面直接交给信令连接**（不经过帧循环），关媒体由帧循环在 `leaveCallbacks` 里做。
 */
extension IMEngineMachine {

    /// forceEnd 算出强制收场的结果。没有进行中的通话也不在房里时原样返回（`emit` 为空）。
    ///
    /// 时长按服务端给的 `connected_at_ms` 估算，与恢复失败时 I8 的那条例外同一个算法：
    /// 本地已经收场，服务端那条带真值的 `call.ended` 随后会因为 idle 被丢掉，没有更准的值可用。
    ///
    /// `reason` 不给就按此刻状态挑（红键）；给了就用它——`room.publish` 被拒时帧循环传 `.error`，
    /// 那不是用户挂的，写成 hangup/cancel/reject 是撒谎（静默失败审计 §A）。
    public static func forceEnd(_ ctx: IMEngineContext,
                                nowMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                                reason reasonOverride: IMCallEndReason? = nil)
        -> IMMachineOutput<IMEngineContext> {
        if ctx.call.state != .idle {
            let call = ctx.call
            let (frames, byState) = endFrames(for: call)
            let reason = reasonOverride ?? byState
            // 从**本端**进来那一刻算（见 `IMEngineContext.callStartedAtMS`）；没记到才退回整通接通时刻。
            let startedAtMS = ctx.callStartedAtMS > 0 ? ctx.callStartedAtMS : call.connectedAtMS
            var next = IMEngineContext()
            next.room = IMRoomMachine.cleared(.idle)
            return IMMachineOutput(next, send: frames, emit: [IMEmittedEvent("onCallEnd", [
                "call_id": .string(call.callID),
                "reason": .string(reason.wireValue),
                "duration_sec": .int(IMCallOutcome.durationSec(connectedAtMS: startedAtMS,
                                                               endedAtMS: nowMS)),
                "ended_by": .string(""),
            ])])
        }
        guard ctx.room.state != .idle else { return IMMachineOutput(ctx) }

        // 没有通话却在房里：会议。结束动作是离房（Kit 的红键在会议里就是 leaveRoom）。
        var send: [IMOutgoingFrame] = []
        if !ctx.room.roomID.isEmpty {
            send.append(IMOutgoingFrame(IMFrameType.roomLeave, ["room_id": .string(ctx.room.roomID)]))
        }
        var next = ctx
        next.room = IMRoomMachine.cleared(.idle)
        return IMMachineOutput(next, send: send, emit: [
            IMEmittedEvent("onRoomLeft", ["room_id": .string(ctx.room.roomID)]),
        ])
    }

    /**
     endFrames 按通话此刻的状态挑结束帧，以及本地收场写哪个结束原因。

     - `accepting` 发 **reject + hangup 两帧**：accept 有没有在服务端落地，本端不知道。
       还在响铃就是 reject 生效（随后那条 hangup 被拒，无害）；已经接起来就是 hangup 生效。
     - `inviting` 还没拿到 call_id（`call.invite.ok` 没回来）时**此刻发不了 cancel**，
       由那条 invite.ok 迟到时补发（`IMFrameLoop.forceEnd` 与 `IMCallMachine.handleLateFrame`）。
     */
    static func endFrames(for call: IMCallContext) -> ([IMOutgoingFrame], IMCallEndReason) {
        let reason: IMCallEndReason
        let types: [String]
        switch call.state {
        case .idle:
            return ([], .hangup)
        case .ringing:
            reason = .reject
            types = [IMFrameType.callReject]
        case .inviting:
            reason = .cancel
            types = [IMFrameType.callCancel]
        case .accepting:
            reason = .hangup
            types = [IMFrameType.callReject, IMFrameType.callHangup]
        case .connecting, .connected:
            reason = .hangup
            types = [IMFrameType.callHangup]
        }
        guard !call.callID.isEmpty else { return ([], reason) }
        return (types.map { IMCallMachine.callIDFrame($0, call) }, reason)
    }
}
