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
        if isForAnotherCall(ctx, data) { return handleForeignCall(ctx, type, data) }
        if type == IMFrameType.callEnded { return handleEnded(ctx, data) }
        if ctx.state == .idle && type != IMFrameType.callIncoming { return handleLateFrame(ctx, type, data) }

        switch type {
        case IMFrameType.callIncoming:
            return handleIncoming(ctx, data)

        case IMEnvelope.okType(IMFrameType.callInvite):
            var next = ctx
            next.callID = Wire.string(data, "call_id")
            next.roomID = Wire.string(data, "room_id")
            // invite.ok 回来之前按过取消（见 `exitCall`）：现在有 call_id 了，立刻补发。
            guard ctx.cancelPending, !next.callID.isEmpty, let exit = IMCallExit.of(.inviting) else { return out(next) }
            next.cancelPending = false
            return out(next, send: exit.frames(callID: next.callID))

        case IMFrameType.callConnected:
            return handleConnected(ctx, data)

        case IMFrameType.callRinging:
            // 服务端发给通话里的所有人（协议 §4.2，2026-09-17 起），界面据此给正在响铃的人摆占位格。
            return out(ctx, emit: [IMEmittedEvent("onUserRinging",
                                                  ["uid": .string(Wire.string(data, "uid"))])])

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

    /**
     这一帧说的是不是**别的一通电话**。

     通话中被第三个人呼叫时，服务端判他忙线并给我们发一条 `call.ended{busy}`——
     那条帧的 `call_id` 是**新来那通**的。原先这里不看 call_id，于是它被当成
     「当前通话结束了」：媒体面直接关掉、通话页收起，而对面还好好地显示着通话中。
     真机日志里就是 08:30:39 那一串 `PC 状态 closed` 紧跟一条别的 call_id 的 callEnd。
    */
    private static func isForAnotherCall(_ ctx: IMCallContext, _ data: [String: IMJSON]) -> Bool {
        let frameCallID = Wire.string(data, "call_id")
        return !ctx.callID.isEmpty && !frameCallID.isEmpty && frameCallID != ctx.callID
    }

    /**
     别的一通电话的帧：**一律不碰当前状态**。

     只有终态帧要露个头——那说明「有人打进来，已经被自动回了忙线」，
     界面据此提示一句谁来过电话（交互规则见 UX_FLOWS §06）。
    */
    private static func handleForeignCall(_ ctx: IMCallContext, _ type: String,
                                          _ data: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        guard type == IMFrameType.callEnded else { return out(ctx) }
        return out(ctx, emit: [IMEmittedEvent("onCallMissed", [
            "call_id": .string(Wire.string(data, "call_id")),
            "caller": .string(Wire.string(data, "caller")),
            "reason": .string(Wire.string(data, "reason")),
        ])])
    }

    /**
     handleLateFrame：idle 下迟到的帧**照旧丢弃**（优先级规则 2），只有两条例外——
     它们说明服务端那边**还有一通挂着本端的电话**，而本地早就收场了
     （红键强制收场时请求还在路上，或请求超时回滚之后应答才到）。
     哪两帧、按什么状态补发结束帧，见 `IMCallExit.serverState(afterLate:)`：
     不补的话 invite.ok 那种被叫一直响到超时，connected 那种服务端一直把本端当成在通话里。

     本地状态不动、不抛回调。补发的帧被拒（比如通话已经结束）只换回一条 onError，无害。
    */
    private static func handleLateFrame(_ ctx: IMCallContext, _ type: String,
                                        _ data: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        let callID = Wire.string(data, "call_id")
        guard !callID.isEmpty,
              let state = IMCallExit.serverState(afterLate: type),
              let exit = IMCallExit.of(state) else { return out(ctx) }
        return out(ctx, send: exit.frames(callID: callID))
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
        // 发起人 / 群号 / user_data 记下来：接通时 call.connected 没带（旧服务端）就回落到这里。
        next.callerUID = Wire.string(data, "caller")
        next.chatGroupID = Wire.string(data, "chat_group_id")
        next.userData = Wire.string(data, "user_data")

        /*
         inviter 是**这次邀请是谁发的**：首次邀请就是主叫，`call.invite_more` 加进来的人
         是发那条加人请求的那个。旧服务端不带这个字段，**空串回落 caller，回落只在这一处**。
         不进 IMCallContext：只有来电那一刻用得到，接通之后没人再问它。
        */
        let rawInviter = Wire.string(data, "inviter")
        let inviter = rawInviter.isEmpty ? next.callerUID : rawInviter

        /*
         **callee_ids 要原样带给宿主。** 群通话里被叫这一侧原先只知道主叫是谁，
         界面上就只能画「已经进来的人」；主叫那边是四格（含还没接的占位格），
         被叫这边是两格，同一通电话两种样子。这条信息服务端一直在发（§4.2 的
         call.incoming），只是没人往上抛。

         群号 / user_data 同理（HOST_INTEGRATION_DESIGN §3.2）：Kit 靠 chat_group_id
         决定「添加成员」列哪个群的人。
        */
        return out(next, emit: [IMEmittedEvent("onCallReceived", [
            "call_id": .string(next.callID),
            "caller": .string(next.callerUID),
            "inviter": .string(inviter),
            "callee_ids": .array(Wire.stringArray(data, "callee_ids").map { .string($0) }),
            // 此刻已在通话里的人；旧服务端不带 = 空，Kit 回落成「只有 caller 在通话里」。
            "joined_ids": .array(Wire.stringArray(data, "joined_ids").map { .string($0) }),
            "media_type": .string(mediaType),
            "is_group": .bool(next.isGroup),
            "chat_group_id": .string(next.chatGroupID),
            "user_data": .string(next.userData),
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
        /*
         **群号 / user_data / 发起人：取 call.connected 里的值，为空时回落到本通
         call.incoming（被叫）或 call() 选项（主叫）里记下的值**（HOST_INTEGRATION_DESIGN
         §3.3）——兼容不带这三个字段的旧服务端。`call.join` 进来的人没收过 call.incoming，
         只能从这一条拿到发起人是谁。
        */
        let connectedCaller = Wire.string(data, "caller")
        let connectedChatGroupID = Wire.string(data, "chat_group_id")
        let connectedUserData = Wire.string(data, "user_data")
        next.callerUID = connectedCaller.isEmpty ? ctx.callerUID : connectedCaller
        next.chatGroupID = connectedChatGroupID.isEmpty ? ctx.chatGroupID : connectedChatGroupID
        next.userData = connectedUserData.isEmpty ? ctx.userData : connectedUserData

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
                       "caller": .string(next.callerUID),
                       "chat_group_id": .string(next.chatGroupID),
                       "user_data": .string(next.userData),
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
