import Foundation

/*
 房间状态机：`RTC_PROTOCOL.md` §5.3。

 一致性向量：`room_fsm.json`，四端跑同一份。

 # 三条不变量（§5.3 的 R1~R3）

 - **R1** 只有 joined 才允许 publish / subscribe / mute；其余状态**本地拒绝**，
   不发上去让服务端报错。
 - **R2** reconnecting 期间**禁止发任何房间帧**，但要把用户意图缓存下来，
   恢复后一次性重放。
 - **R3** 订阅与换层是**幂等**的：重复 subscribe 同一条 track 等价于换层。
 */

/// 房间连接状态。
public enum IMRoomState: String, Sendable {
    case idle, joining, joined, leaving, reconnecting
}

/// 一条本端 Track 的发布状态。
public enum IMPublishState: String, Sendable {
    case publishing, published, unpublishing
}

/// 一条远端 Track 的订阅状态。
public enum IMSubscribeState: String, Sendable {
    case subscribing, subscribed, unsubscribing
}

/// 远端 Track 的本地记账。
public struct IMRemoteTrack: Equatable, Sendable {
    public let uid: String
    /// "audio" 或 "video"。
    public let kind: String
    public let participantID: String
}

/// 房间状态机持有的全部数据。
public struct IMRoomContext: Equatable, Sendable {
    public var state: IMRoomState = .idle
    public var roomID: String = ""
    public var roomToken: String = ""
    public var participantID: String = ""
    public var autoSubscribe: Bool = true
    /// cid → 发布状态。用 cid 而不是 track_id：发布请求发出时还没有 track_id。
    public var publish: [String: IMPublishState] = [:]
    /// cid → 服务端分配的 track_id。
    public var publishTrackIDs: [String: String] = [:]
    /// track_id → 订阅状态。
    public var subscribe: [String: IMSubscribeState] = [:]
    /// track_id → 远端 Track 记账。`track_unpublished` 帧不带 kind，只能靠它。
    public var remoteTracks: [String: IMRemoteTrack] = [:]
    /// 期望的最高层。track_id → layer。
    public var layers: [String: String] = [:]
    /// reconnecting 期间缓存的用户意图（不变量 R2）。
    public var buffered: [IMOutgoingFrame] = []

    public init() {}
}

public enum IMRoomMachine {
    /// reduce 是房间状态机的唯一入口。
    public static func reduce(_ ctx: IMRoomContext,
                              _ input: IMMachineInput) -> IMMachineOutput<IMRoomContext> {
        switch input {
        case let .act(op, args):
            return reduceAct(ctx, op, args)
        case let .recv(type, data):
            return reduceRecv(ctx, type, data)
        case let .internalEvent(name):
            return reduceInternal(ctx, name)
        }
    }

    static func out(_ ctx: IMRoomContext,
                    send: [IMOutgoingFrame] = [],
                    emit: [IMEmittedEvent] = []) -> IMMachineOutput<IMRoomContext> {
        IMMachineOutput(ctx, send: send, emit: emit)
    }

    /// cleared 把房间相关的记账全部清空，state 由调用方决定。
    static func cleared(_ state: IMRoomState) -> IMRoomContext {
        var ctx = IMRoomContext()
        ctx.state = state
        return ctx
    }

    private static func reduceInternal(_ ctx: IMRoomContext,
                                       _ name: String) -> IMMachineOutput<IMRoomContext> {
        switch name {
        case "disconnected":
            // 断线**不等于**离房：协议给了 30 秒恢复窗口，房内其他人这时还看得见我们。
            if ctx.state == .idle { return out(ctx) }
            var next = ctx
            next.state = .reconnecting
            return out(next)
        case "ws_closed_4403", "reset":
            return out(cleared(.idle))
        default:
            return out(ctx)
        }
    }

    /// resume 在重连成功后恢复房间：重放缓存的用户意图。
    ///
    /// `resumed == false` 时**必须回到 idle 并重新 join**（§1.4）——
    /// 服务端那边的成员关系已经过期了，装作还在只会让 UI 撒谎。
    public static func resume(_ ctx: IMRoomContext,
                              resumed: Bool) -> IMMachineOutput<IMRoomContext> {
        guard resumed else { return out(cleared(.idle)) }
        guard ctx.state == .reconnecting else { return out(ctx) }
        var next = ctx
        next.state = .joined
        next.buffered = []
        return out(next, send: ctx.buffered)
    }

    private static func reduceAct(_ ctx: IMRoomContext, _ op: String,
                                  _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        if op == "join" { return joinRoom(ctx, args) }
        if op == "leave" {
            guard ctx.state == .joined else { return localReject(ctx) }
            var next = ctx
            next.state = .leaving
            return out(next, send: [IMOutgoingFrame(IMFrameType.roomLeave,
                                                    ["room_id": .string(ctx.roomID)])])
        }

        // R1：只有 joined 才允许发布/订阅类操作。
        // R2：reconnecting 期间把意图缓存下来，恢复后重放——不是丢掉，也不是发上去。
        if ctx.state == .reconnecting { return bufferIntent(ctx, op, args) }
        guard ctx.state == .joined else { return localReject(ctx) }

        switch op {
        case "publish": return publishTrack(ctx, args)
        case "unpublish": return unpublishTrack(ctx, args)
        case "mute":
            return out(ctx, send: [IMOutgoingFrame(IMFrameType.roomMute, muteData(args))])
        case "subscribe": return subscribeTrack(ctx, args)
        case "unsubscribe": return unsubscribeTrack(ctx, args)
        case "update_layer": return updateLayer(ctx, args)
        default: return localReject(ctx)
        }
    }

    private static func joinRoom(_ ctx: IMRoomContext,
                                 _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        guard ctx.state == .idle else { return localReject(ctx) }
        // auto_subscribe 默认 true——直接读 args 会把「没写」当成 false，
        // 那正是 §2.4 点名的发送侧陷阱。
        let autoSubscribe = args["auto_subscribe"]?.boolValue ?? true
        let roomID = Wire.string(args, "room_id")
        let roomToken = Wire.string(args, "room_token")

        var next = ctx
        next.state = .joining
        next.roomID = roomID
        next.roomToken = roomToken
        next.autoSubscribe = autoSubscribe

        return out(next, send: [IMOutgoingFrame(IMFrameType.roomJoin, [
            "room_id": .string(roomID),
            "room_token": .string(roomToken),
            "auto_subscribe": .bool(autoSubscribe),
        ])])
    }

    private static func publishTrack(_ ctx: IMRoomContext,
                                     _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let cid = Wire.string(args, "cid")
        var next = ctx
        next.publish[cid] = .publishing
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomPublish, [
            "cid": .string(cid),
            "kind": .string(Wire.string(args, "kind")),
            "source": .string(Wire.string(args, "source")),
            "simulcast": .bool(Wire.bool(args, "simulcast")),
        ])])
    }

    private static func unpublishTrack(_ ctx: IMRoomContext,
                                       _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let trackID = Wire.string(args, "track_id")
        var next = ctx
        if let cid = ctx.publishTrackIDs.first(where: { $0.value == trackID })?.key {
            next.publish[cid] = .unpublishing
        }
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomUnpublish,
                                                ["track_id": .string(trackID)])])
    }

    /// subscribeTrack：**重复订阅等价于换层**（不变量 R3）。
    ///
    /// 客户端的订阅与服务端的 track_unpublished 天然会赛跑，所以这条路径必须幂等。
    private static func subscribeTrack(_ ctx: IMRoomContext,
                                       _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let trackID = Wire.string(args, "track_id")
        let layer = Wire.string(args, "max_layer").isEmpty ? "m" : Wire.string(args, "max_layer")

        var next = ctx
        next.layers[trackID] = layer
        if ctx.subscribe[trackID] != nil {
            return out(next, send: [IMOutgoingFrame(IMFrameType.roomUpdateLayer, [
                "track_id": .string(trackID), "max_layer": .string(layer),
            ])])
        }
        next.subscribe[trackID] = .subscribing
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomSubscribe, [
            "track_id": .string(trackID), "max_layer": .string(layer),
        ])])
    }

    private static func unsubscribeTrack(_ ctx: IMRoomContext,
                                         _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let trackID = Wire.string(args, "track_id")
        var next = ctx
        next.subscribe[trackID] = .unsubscribing
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomUnsubscribe,
                                                ["track_id": .string(trackID)])])
    }

    private static func updateLayer(_ ctx: IMRoomContext,
                                    _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        let trackID = Wire.string(args, "track_id")
        let layer = Wire.string(args, "max_layer").isEmpty ? "m" : Wire.string(args, "max_layer")
        var next = ctx
        next.layers[trackID] = layer
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomUpdateLayer, [
            "track_id": .string(trackID), "max_layer": .string(layer),
        ])])
    }

    /// bufferIntent 把 reconnecting 期间的用户意图缓存起来（不变量 R2）。
    private static func bufferIntent(_ ctx: IMRoomContext, _ op: String,
                                     _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        guard op == "mute" else { return out(ctx) } // 只有开关麦/摄像头值得重放
        var next = ctx
        next.buffered.append(IMOutgoingFrame(IMFrameType.roomMute, muteData(args)))
        return out(next)
    }

    private static func muteData(_ args: [String: IMJSON]) -> [String: IMJSON] {
        ["track_id": .string(Wire.string(args, "track_id")), "muted": .bool(Wire.bool(args, "muted"))]
    }

    /// localReject 是不变量 R1 的落点：错误状态下的调用**本地拒绝**，不发上去。
    static func localReject(_ ctx: IMRoomContext) -> IMMachineOutput<IMRoomContext> {
        out(ctx, emit: [IMEmittedEvent("onError", [
            "code": .int(Int64(IMErrorCode.invalidState.rawValue)),
            "name": .string(IMErrorCode.invalidState.name),
        ])])
    }
}
