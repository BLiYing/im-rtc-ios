import Foundation

/*
 通话状态机的**下行帧**分支（§5.1 转移表的右半边）。

 与 CallStateMachine.swift 拆开是体量红线（CONVENTIONS §2）——
 「上行动作」与「下行帧」本来也是两组独立的关注点。
 */
extension IMCallMachine {
    /// reduceRecv 处理一条下行帧。
    ///
    /// 两条优先级规则写在最前面，**别挪**：
    /// 1. **终态帧优先**——任何非 idle 状态收到 call.ended 都直达 idle（§5.1）。
    /// 2. **idle 下的迟到帧一律静默丢弃**：不抛回调、不发帧、不报错。
    ///    本地状态与服务端赛跑是正常的，客户端得容忍。
    static func reduceRecv(_ ctx: IMCallContext, _ type: String,
                           _ data: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        if type == IMFrameType.callEnded { return handleEnded(ctx, data) }
        if ctx.state == .idle && type != IMFrameType.callIncoming { return out(ctx) }

        switch type {
        case IMFrameType.callIncoming:
            return handleIncoming(ctx, data)

        case IMEnvelope.okType(IMFrameType.callInvite):
            var next = ctx
            next.callID = Wire.string(data, "call_id")
            next.roomID = Wire.string(data, "room_id")
            return out(next)

        case IMFrameType.callConnected:
            return handleConnected(ctx, data)

        case IMFrameType.callAccepted:
            return out(ctx, emit: [IMEmittedEvent("onUserAccept",
                                                  ["uid": .string(Wire.string(data, "uid"))])])

        case IMFrameType.callRejected:
            return handleOutcome(ctx, data, userCB: "onUserReject", convenienceCB: "onCallRejected")

        case IMFrameType.callNoAnswer:
            return handleOutcome(ctx, data, userCB: "onUserNoResponse", convenienceCB: "onCallNoAnswer")

        case IMFrameType.callBusy:
            // 忙线没有对应的 onUser*——被叫压根没振铃（§4.3）。
            return ctx.isGroup
                ? out(ctx)
                : out(ctx, emit: [IMEmittedEvent("onCallBusy",
                                                 ["uid": .string(Wire.string(data, "uid"))])])

        case IMFrameType.callCancelled:
            return out(ctx, emit: [IMEmittedEvent("onCallCancelled",
                                                  ["by": .string(Wire.string(data, "by"))])])

        case IMFrameType.callHandledElsewhere:
            return out(ctx, emit: [IMEmittedEvent("onHandledOnOtherDevice", [
                "call_id": .string(Wire.string(data, "call_id")),
                "action": .string(Wire.string(data, "action")),
            ])])

        default:
            // 其余（call.ringing、各种 .ok）不改状态也不抛回调。
            return out(ctx)
        }
    }

    private static func handleIncoming(_ ctx: IMCallContext,
                                       _ data: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        guard ctx.state == .idle else { return out(ctx) }
        let mediaType = Wire.string(data, "media_type") == "video" ? "video" : "audio"

        var next = ctx
        next.state = .ringing
        next.role = .callee
        next.callID = Wire.string(data, "call_id")
        next.roomID = Wire.string(data, "room_id")
        next.mediaType = mediaType
        next.isGroup = Wire.bool(data, "is_group")

        return out(next, emit: [IMEmittedEvent("onCallReceived", [
            "call_id": .string(next.callID),
            "caller": .string(Wire.string(data, "caller")),
            "media_type": .string(mediaType),
            "is_group": .bool(next.isGroup),
        ])])
    }

    /// handleConnected：拿到 room_token，抛 onCallBegin，并**立刻发 room.join**。
    ///
    /// onCallBegin 抛在进入 connecting 时（不是 connected）——草图 §09 的时序就是这样：
    /// 双方在 call.connected 那一刻同时开始计时。
    private static func handleConnected(_ ctx: IMCallContext,
                                        _ data: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        guard ctx.state == .inviting || ctx.state == .ringing || ctx.state == .accepting else {
            return out(ctx)
        }
        let roomID = Wire.string(data, "room_id")
        let roomToken = Wire.string(data, "room_token")
        let mediaType = Wire.string(data, "media_type") == "video" ? "video" : ctx.mediaType
        let callID = Wire.string(data, "call_id")

        var next = ctx
        next.state = .connecting
        next.callID = callID.isEmpty ? ctx.callID : callID
        next.roomID = roomID
        next.roomToken = roomToken
        next.mediaType = mediaType
        next.isGroup = Wire.bool(data, "is_group") || ctx.isGroup
        next.connectedAtMS = Wire.int(data, "connected_at_ms")

        return out(next,
                   send: [IMOutgoingFrame(IMFrameType.roomJoin, [
                       "room_id": .string(roomID),
                       "room_token": .string(roomToken),
                   ])],
                   emit: [IMEmittedEvent("onCallBegin", [
                       "call_id": .string(next.callID),
                       "room_id": .string(roomID),
                       "media_type": .string(mediaType),
                       "is_group": .bool(next.isGroup),
                       "role": .string(next.role.rawValue),
                   ])])
    }

    /// handleOutcome 处理某成员的裁决。
    ///
    /// **便利事件只在 1v1 抛**（不变量 I7）：群里一个人拒接，通话还在继续，
    /// 后面并不会紧跟 onCallEnd，抛便利事件就自相矛盾了。
    private static func handleOutcome(_ ctx: IMCallContext, _ data: [String: IMJSON],
                                      userCB: String,
                                      convenienceCB: String) -> IMMachineOutput<IMCallContext> {
        let uid = Wire.string(data, "uid")
        var emit = [IMEmittedEvent(userCB, ["uid": .string(uid)])]
        if !ctx.isGroup { emit.append(IMEmittedEvent(convenienceCB, ["uid": .string(uid)])) }
        return out(ctx, emit: emit)
    }

    /// handleEnded：唯一的终态处理。
    ///
    /// **收到 call.ended 后禁止再发 room.leave**（不变量 I6）——服务端在结束通话时
    /// 已经清掉了房间成员，再发只会换回 1201/1203。
    private static func handleEnded(_ ctx: IMCallContext,
                                    _ data: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        guard ctx.state != .idle else { return out(ctx) }
        let reason = IMCallEndReason.from(wire: Wire.string(data, "reason"))
        return out(IMCallContext(), emit: [IMEmittedEvent("onCallEnd", [
            "call_id": .string(Wire.string(data, "call_id")),
            "reason": .string(reason.wireValue),
            "duration_sec": .int(Wire.int(data, "duration_sec")),
            "ended_by": .string(Wire.string(data, "ended_by")),
        ])])
    }
}
