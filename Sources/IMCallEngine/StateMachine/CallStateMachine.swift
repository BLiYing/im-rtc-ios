import Foundation

/*
 通话状态机：`RTC_PROTOCOL.md` §5.1。

 一致性向量：`call_fsm.json`，四端跑同一份。

 # 三条容易写错的地方

 1. **没有 `ended` 状态**——ended 是事件不是状态。草图 §09 里那个「停 1.5 秒」的
    方框是 Kit 的展示状态，由 Kit 自己持有（不变量 I5）。
 2. **便利事件只在 1v1 抛**（onCallCancelled/Rejected/Busy/NoAnswer）。群通话里
    某人拒接只抛 onUserReject——否则会违反「便利事件后必定跟 onCallEnd」（I7）。
 3. **状态只由信令帧与宿主调用驱动，禁止由定时器改状态**（I4）。
    本地振铃倒计时只改 UI，超时由服务端裁决。
 */

/// 通话状态。**没有 ended**，见文件头。
public enum IMCallState: String, Sendable {
    case idle
    case inviting
    case ringing
    case accepting
    case connecting
    case connected
}

/// 本端在这通电话里的角色。
public enum IMCallRole: String, Sendable {
    case none = ""
    case caller
    case callee
}

/// 通话状态机持有的全部数据。
public struct IMCallContext: Equatable, Sendable {
    public var state: IMCallState = .idle
    public var callID: String = ""
    public var roomID: String = ""
    public var roomToken: String = ""
    public var mediaType: String = "audio"
    public var isGroup: Bool = false
    public var role: IMCallRole = .none
    /// 通话时长的起点，来自服务端。**客户端不自己算时长**（I8）。
    public var connectedAtMS: Int64 = 0

    public init() {}
}

public enum IMCallMachine {
    /// reduce 是通话状态机的唯一入口。
    public static func reduce(_ ctx: IMCallContext,
                              _ input: IMMachineInput) -> IMMachineOutput<IMCallContext> {
        switch input {
        case let .act(op, args):
            return reduceAct(ctx, op, args)
        case let .recv(type, data):
            return reduceRecv(ctx, type, data)
        case let .internalEvent(name):
            return reduceInternal(ctx, name)
        }
    }

    static func out(_ ctx: IMCallContext,
                    send: [IMOutgoingFrame] = [],
                    emit: [IMEmittedEvent] = []) -> IMMachineOutput<IMCallContext> {
        IMMachineOutput(ctx, send: send, emit: emit)
    }

    private static func reduceInternal(_ ctx: IMCallContext,
                                       _ name: String) -> IMMachineOutput<IMCallContext> {
        /*
         **`call.invite` 被服务端拒了要回 idle**，与 `join_failed` 同一个道理。

         不退的话通话机永远停在 `inviting`：界面上「正在呼叫…」转个不停，
         而服务端根本没建这通电话；随后每次挂断都发向一个不存在的 call，
         换回 `1401 call_not_found`，**永远退不出去**。
         （实测：群呼把主叫自己也放进了 callee_ids，服务端回 1004，
         接着连点五次挂断全是 1401。）

         抛 onCallEnd 而不是只清状态：它是所有结束分支的唯一出口（设计 §7.5），
         界面只认这一个信号来收场子。reason 用 error——这通电话从未建立，
         hangup / cancel / reject 哪个都不是实情。
        */
        if name == "call_failed", ctx.state != .idle {
            return out(IMCallContext(), emit: [IMEmittedEvent("onCallEnd", [
                "call_id": .string(ctx.callID),
                "reason": .string(IMCallEndReason.error.wireValue),
                "duration_sec": .int(0),
                "ended_by": .string(""),
            ])])
        }
        // 媒体就绪 = room.join.ok 到手 + sub PC 的 ICE 连通（§5.1）。
        guard name == "media_ready", ctx.state == .connecting else { return out(ctx) }
        var next = ctx
        next.state = .connected
        return out(next)
    }

    private static func reduceAct(_ ctx: IMCallContext, _ op: String,
                                  _ args: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        switch op {
        case "call":
            return startCall(ctx, args)
        case "accept":
            return acceptCall(ctx)
        case "reject":
            // reject 只发帧，状态由随后的 call.ended 推进——**服务端才是裁决方**。
            return ctx.state == .ringing
                ? out(ctx, send: [callIDFrame(IMFrameType.callReject, ctx)])
                : invalidState(ctx)
        case "cancel":
            return ctx.state == .inviting
                ? out(ctx, send: [callIDFrame(IMFrameType.callCancel, ctx)])
                : invalidState(ctx)
        case "hangup":
            return ctx.state == .connected || ctx.state == .connecting
                ? out(ctx, send: [callIDFrame(IMFrameType.callHangup, ctx)])
                : invalidState(ctx)
        case "invite_more":
            return inviteMore(ctx, args)
        case "join_call":
            return joinOngoingCall(ctx, args)
        default:
            return invalidState(ctx)
        }
    }

    private static func startCall(_ ctx: IMCallContext,
                                  _ args: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        guard ctx.state == .idle else { return invalidState(ctx) }

        let calleeIDs = Wire.stringArray(args, "callee_ids")
        let mediaType = Wire.string(args, "media_type") == "video" ? "video" : "audio"
        let isGroup = Wire.bool(args, "is_group")

        var next = ctx
        next.state = .inviting
        next.role = .caller
        next.mediaType = mediaType
        next.isGroup = isGroup

        return out(next, send: [IMOutgoingFrame(IMFrameType.callInvite, [
            "callee_ids": .array(calleeIDs.map { .string($0) }),
            "media_type": .string(mediaType),
            "is_group": .bool(isGroup),
        ])])
    }

    private static func acceptCall(_ ctx: IMCallContext) -> IMMachineOutput<IMCallContext> {
        // 第二次 accept 必须**本地**拦下，不能发上去让服务端回 1405。
        guard ctx.state == .ringing else { return invalidState(ctx) }
        var next = ctx
        next.state = .accepting
        return out(next, send: [callIDFrame(IMFrameType.callAccept, ctx)])
    }

    private static func inviteMore(_ ctx: IMCallContext,
                                   _ args: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        guard ctx.state == .connected || ctx.state == .connecting else { return invalidState(ctx) }
        return out(ctx, send: [IMOutgoingFrame(IMFrameType.callInviteMore, [
            "call_id": .string(ctx.callID),
            "callee_ids": .array(Wire.stringArray(args, "callee_ids").map { .string($0) }),
        ])])
    }

    /// joinOngoingCall 是「群成员看到『进行中』主动加入」（§4.1）。
    ///
    /// **「怎么知道有通话在进行中」不在本协议里**——那是宿主拿 webhook `call.started`
    /// 自己发广播的事。Engine 只负责把 call_id 送上去。
    private static func joinOngoingCall(_ ctx: IMCallContext,
                                        _ args: [String: IMJSON]) -> IMMachineOutput<IMCallContext> {
        guard ctx.state == .idle else { return invalidState(ctx) }
        let callID = Wire.string(args, "call_id")
        var next = ctx
        next.state = .accepting
        next.role = .callee
        next.callID = callID
        next.isGroup = true
        return out(next, send: [IMOutgoingFrame(IMFrameType.callJoin, ["call_id": .string(callID)])])
    }

    static func callIDFrame(_ type: String, _ ctx: IMCallContext) -> IMOutgoingFrame {
        IMOutgoingFrame(type, ["call_id": .string(ctx.callID)])
    }

    static func invalidState(_ ctx: IMCallContext) -> IMMachineOutput<IMCallContext> {
        out(ctx, emit: [IMEmittedEvent("onError", [
            "code": .int(Int64(IMErrorCode.invalidState.rawValue)),
            "name": .string(IMErrorCode.invalidState.name),
        ])])
    }

    /// synthesizeNetworkEnd 是不变量 I8 的那个**唯一例外**。
    ///
    /// 重连恢复失败时服务端那条 `call.ended` 已经送不到我们手里了，
    /// 只能本地合成一条——否则宿主会永远等不到 onCallEnd，界面卡在通话中。
    public static func synthesizeNetworkEnd(_ ctx: IMCallContext,
                                            nowMS: Int64) -> IMMachineOutput<IMCallContext> {
        guard ctx.state != .idle else { return out(ctx) }
        let duration = IMCallOutcome.durationSec(connectedAtMS: ctx.connectedAtMS, endedAtMS: nowMS)
        return out(IMCallContext(), emit: [IMEmittedEvent("onCallEnd", [
            "call_id": .string(ctx.callID),
            "reason": .string(IMCallEndReason.network.wireValue),
            "duration_sec": .int(duration),
            "ended_by": .string(""),
        ])])
    }
}
