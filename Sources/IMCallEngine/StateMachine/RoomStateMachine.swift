import Foundation

/*
 房间状态机：`RTC_PROTOCOL.md` §5.3。

 一致性向量：`room_fsm.json`，四端跑同一份。

 # 三条不变量（§5.3 的 R1~R3）

 - **R1** 只有 joined 才允许 publish / subscribe / mute；其余状态**本地拒绝**，
   不发上去让服务端报错。
 - **R2** joining 与 reconnecting 期间**禁止发任何房间帧**，但要把用户意图
   缓存下来，进房/恢复后一次性重放。这两个状态的共同点是**宿主观察不到**——
   它拿到 onCallBegin 就推流是最自然的写法，不该因为一个内部中间态而失败。
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
    /// joining / reconnecting 期间缓存的用户意图（不变量 R2）。
    public var buffered: [IMBufferedIntent] = []
    /**
     这个房间**真的收到过 `room.join.ok`** 吗。

     只有它能区分 `reconnecting` 的两种来路：从 `joined` 断的（服务端那边成员关系还在，
     恢复后直接回 `joined`），还是从 `joining` 断的（`room.join` 还在飞，服务端从没受理过）。
     少了它，`resume` 会把后者也宣布成 `joined`——见 ``IMRoomMachine/resume(_:resumed:)``。

     不进一致性向量：向量只断言 `room` / `publish` / `subscribe` 那几个键，
     这是本端为了分辨来路自己记的账。
     */
    public var didJoin = false

    public init() {}
}

/// 攒下来的一次调用，**存的是意图不是帧**。
///
/// 存帧的话重放时只能原样发出去，状态（比如 `publish[cid] = .publishing`）就漏掉了；
/// 存意图则可以在 joined 态重新走一遍正常路径，跟没缓存过一模一样。
public struct IMBufferedIntent: Equatable, Sendable {
    public let op: String
    public let args: [String: IMJSON]
}

public enum IMRoomMachine {
    /// 值得攒下来重放的操作——正好是 R1 管的那一组。
    static let bufferableOps: Set<String> = [
        "publish", "unpublish", "mute", "subscribe", "unsubscribe", "update_layer",
    ]
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
        case "join_failed":
            /*
             进房被拒（房间没了、票过期、已在房里…）。**退回 idle**，
             否则状态机永远停在 joining，之后每次 publish 都被 R1 本地拒成 2005。

             **还要抛 onRoomLeft**：只清状态的话宿主什么都不知道，会议界面会一直停在
             「正在进入会议…」——和「呼叫被拒却不回 idle」是同一类毛病，
             界面需要一个明确的收场信号，房间的收场信号就是这一条。

             （这个分支 iOS 上原先整个没有：FrameLoop 发了 join_failed，
             但没人接——所以进房失败之后这台 Engine 就再也进不了任何房间了。）
            */
            guard ctx.state == .joining else { return out(ctx) }
            return out(cleared(.idle),
                       emit: [IMEmittedEvent("onRoomLeft", ["room_id": .string(ctx.roomID)])])
        case "leave_failed":
            /*
             离房被拒。**照样退回 idle**——这是 join_failed 的镜像，漏掉它的代价更大。

             `room.leave` 会被拒是真事：服务端在「会话已不在房间里」时回 1203
             （两人同时离房、或房间刚被「已空，已关闭」销毁掉，都撞得上）。
             而被拒的语义恰恰是**我们已经不在房里了**，本地却还停在 leaving：
             媒体停不掉（摄像头、麦克风一直开着），再 leave 被 R1 拒成 2005，
             再 join 因为「不在 idle」也被拒——除非 logout，这台 Engine 永远进不了房。

             所以「被拒」与「leave.ok」在本地是同一个收场：归零 + onRoomLeft。
             （Android 的 `IMRoomMachine` 一直有这一支。）
            */
            guard ctx.state == .leaving else { return out(ctx) }
            return out(cleared(.idle),
                       emit: [IMEmittedEvent("onRoomLeft", ["room_id": .string(ctx.roomID)])])
        default:
            return out(ctx)
        }
    }

    /**
     resume 在重连成功后恢复房间：重放缓存的用户意图。

     `resumed == false` 时**必须回到 idle 并重新 join**（§1.4）——
     服务端那边的成员关系已经过期了，装作还在只会让 UI 撒谎。

     # `reconnecting` 有两种来路，不能一视同仁

     `disconnected` 会把**任何**非 idle 状态推进 `reconnecting`，`joining` 也在内。
     而从 `joining` 断的那一种，`room.join` 当时还在飞：服务端从没受理过我们，
     恢复的只是那条 WS 会话，**不是房间成员关系**。原先这里无条件宣布 `joined`，
     于是本端以为自己在房里，之后每一帧都换回 1201/1203，
     而重新 join 又因为「不在 idle」被本地拒成 2005——一个哑掉的死局。

     （那条本该兜住它的 `join_failed` 指望不上：`rejectAll` 唤醒的是隔着两跳 actor 的
     `IMFrameSender`，而 `disconnected` 走帧泵，`IMFrameLoop` 又是可重入 actor——
     `disconnected` 完全可能先到，随后的 `join_failed` 因为 `guard state == .joining`
     变成空操作。所以不能靠时序，要靠 `didJoin` 这笔账。）

     所以这一种走的是**重发一次 `room.join`**：房号与房票都还在手上，
     该做的正是把那次没落地的进房重来一遍，攒下的意图也照旧留着等进房后重放。
     */
    public static func resume(_ ctx: IMRoomContext,
                              resumed: Bool) -> IMMachineOutput<IMRoomContext> {
        guard resumed else { return out(cleared(.idle)) }
        guard ctx.state == .reconnecting else { return out(ctx) }
        guard ctx.didJoin else { return rejoin(ctx) }
        var joined = ctx
        joined.state = .joined
        return replayBuffered(joined)
    }

    /// rejoin 把「进房还没落地就断了」的那一轮重发一遍。**攒下的意图原样留着。**
    ///
    /// - Note: 这里不记日志——状态机是纯函数（CONVENTIONS §2），
    ///   不碰网络、不碰 UI、也不写日志，否则一致性向量就不是纯输入输出了。
    private static func rejoin(_ ctx: IMRoomContext) -> IMMachineOutput<IMRoomContext> {
        guard !ctx.roomID.isEmpty else {
            // 连房号都没有（`join` 的帧还没产出就断了）：没得重发，干净地回 idle。
            return out(cleared(.idle))
        }
        var next = ctx
        next.state = .joining
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomJoin, [
            "room_id": .string(ctx.roomID),
            "room_token": .string(ctx.roomToken),
            "auto_subscribe": .bool(ctx.autoSubscribe),
        ])])
    }

    /// replayBuffered 在 joined 态把攒下的意图重新走一遍。
    ///
    /// **重放走的是正常路径**（reduceAct），不是把缓存的帧直接吐出去——
    /// 这样状态更新与帧生成永远一致，不会出现「帧发了但本地记账没跟上」。
    static func replayBuffered(_ ctx: IMRoomContext) -> IMMachineOutput<IMRoomContext> {
        guard !ctx.buffered.isEmpty else { return out(ctx) }

        var state = ctx
        state.buffered = []
        var send: [IMOutgoingFrame] = []
        var emit: [IMEmittedEvent] = []
        for intent in ctx.buffered {
            let result = reduceAct(state, intent.op, intent.args)
            state = result.state
            send.append(contentsOf: result.send)
            emit.append(contentsOf: result.emit)
        }
        return out(state, send: send, emit: emit)
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
        // R2：**joining 与 reconnecting** 期间把意图缓存下来，之后重放——
        //     不是丢掉，也不是发上去。这两个状态宿主都观察不到，
        //     在它们上面报「状态非法」等于让宿主为一个内部细节买单。
        if ctx.state == .joining || ctx.state == .reconnecting {
            return bufferIntent(ctx, op, args)
        }
        guard ctx.state == .joined else { return localReject(ctx) }

        switch op {
        case "publish": return publishTrack(ctx, args)
        case "unpublish": return unpublishTrack(ctx, args)
        case "mute":
            return out(ctx, send: [IMOutgoingFrame(IMFrameType.roomMute, muteData(args))])
        case "subscribe": return subscribeTrack(ctx, args)
        case "unsubscribe": return unsubscribeTrack(ctx, args)
        case "update_layer": return updateLayer(ctx, args)
        /*
         上行那条 PC 断了，重新 offer 一次把 ICE 打回来（媒体层已经把 restart 位置好了）。
         **不进 bufferableOps**：这是「此刻网断了」的即时反应，等到重放的时候
         那条 PC 早就换过一轮了，补发一个过期的重启只会白折腾一次协商。
        */
        case "restart_pub_ice":
            return out(ctx, send: [IMOutgoingFrame(IMFrameType.roomOffer,
                                                   ["pc": .string("pub"), "sdp": .string("")])])
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

    /// bufferIntent 把中间态期间的用户意图缓存起来（不变量 R2）。
    private static func bufferIntent(_ ctx: IMRoomContext, _ op: String,
                                     _ args: [String: IMJSON]) -> IMMachineOutput<IMRoomContext> {
        // 不认识的 op 照旧本地拒绝：缓存的是**合法但来早了**的调用，不是笔误。
        guard bufferableOps.contains(op) else { return localReject(ctx) }
        var next = ctx
        next.buffered.append(IMBufferedIntent(op: op, args: args))
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
