import Foundation

/*
 Engine 的总状态：把通话机与房间机合起来，并处理**只有「合起来」才说得清**的事。

 四件事：
 1. **连接级事件**（onConnected / onDisconnected / onKickedOut）由这里抛——
    它们既不属于某次通话，也不属于某个房间。
 2. **重连恢复失败**时，房间回 idle **且**通话要本地合成 onCallEnd(network)
    （不变量 I8）——服务端那条 ended 帧送不到我们手里了。
 3. **通话机产出的 room.join** 要转成房间机的 join 动作，否则房间机不知道
    自己正在进房，之后的 join.ok 就没人接。
 4. **通话结束时房间要回 idle**。这条是 3 的反向，漏了它的后果比漏 3 还隐蔽：
    call.ended 之后服务端就把房间销毁了，而房间机还停在 joined，
    于是之后每一帧都发向一个已经不存在的房间（服务端回 1201），
    下一次 join 还会因为「不在 idle」被本地拒掉——界面永远停在「接通中」。
    （这一条是 Web 端浏览器双开时抓到的真 bug，三端都要有。）
 */
public struct IMEngineContext: Equatable, Sendable {
    public var room = IMRoomContext()
    public var call = IMCallContext()

    public init() {}
}

public enum IMEngineMachine {
    private static let callActs: Set<String> = [
        "call", "accept", "reject", "cancel", "hangup", "invite_more", "join_call",
    ]
    private static let roomActs: Set<String> = [
        "join", "leave", "publish", "unpublish", "mute", "subscribe", "unsubscribe", "update_layer",
        "restart_pub_ice",
    ]

    /// reduce 是 engine 状态的唯一入口。
    public static func reduce(_ ctx: IMEngineContext, _ input: IMMachineInput,
                              nowMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000))
        -> IMMachineOutput<IMEngineContext> {
        switch input {
        case let .recv(type, data) where type == IMEnvelope.okType(IMFrameType.hello):
            return handleHelloOK(ctx, data, nowMS: nowMS)
        case let .recv(type, data):
            return routeFrame(ctx, type: type, data: data)
        case let .internalEvent(name):
            return handleInternal(ctx, name, nowMS: nowMS)
        case let .act(op, args):
            return routeAct(ctx, op: op, args: args)
        }
    }

    /// handleHelloOK：握手成功。
    ///
    /// `resumed == false` 时**房间与通话都要归零**——服务端那边的会话已经过期，
    /// 装作还在只会让 UI 撒谎。
    private static func handleHelloOK(_ ctx: IMEngineContext, _ data: [String: IMJSON],
                                      nowMS: Int64) -> IMMachineOutput<IMEngineContext> {
        let resumed = Wire.bool(data, "resumed")
        let connected = IMEmittedEvent("onConnected", [
            "session_id": .string(Wire.string(data, "session_id")),
            "resumed": .bool(resumed),
        ])

        guard resumed else {
            let dropped = dropLostSession(ctx, nowMS: nowMS)
            return IMMachineOutput(dropped.state,
                                   send: dropped.send,
                                   emit: [connected] + dropped.emit)
        }

        let room = IMRoomMachine.resume(ctx.room, resumed: true)
        var next = ctx
        next.room = room.state
        return IMMachineOutput(next, send: room.send, emit: [connected] + room.emit)
    }

    /// dropLostSession 收拾「服务端那侧的会话已经没了」这一件事：房间与通话都要收场。
    ///
    /// 「重连上了但 `resumed == false`」与「断得太久 `session_unrecoverable`」是同一件事
    /// 的两个到达时机，所以共用这一段。
    ///
    /// # 必须给宿主一个收场信号
    ///
    /// `IMRoomMachine.resume(_:resumed: false)` 只是把房间清成 idle，**一个事件都不抛**。
    /// 有 call 的场合还有 `onCallEnd(network)` 兜着，可**会议是直接 joinRoom 的、
    /// 压根没有 call**——于是房间机悄悄回了 idle，而界面还显示着「会议中」、计时器还在走，
    /// 用户完全不知道自己已经掉出去了；更糟的是一个结束类回调都没抛，
    /// `IMFrameLoop` 的 `leaveCallbacks` 不命中，`media.close()` 永远不调用，
    /// **摄像头与麦克风一直开着**，上一轮的 PeerConnection 还会被带进下一次进房。
    ///
    /// 所以：有通话就抛 `onCallEnd`（唯一出口，不再补 `onRoomLeft`，否则宿主记两遍账），
    /// 没通话但在房里就补一条 `onRoomLeft`——房间的收场信号就是它。
    /// **三端同源**：Web 的 `engineMachine.dropLostSession`、Android 的
    /// `IMEngineMachine.dropLostSession` 是同一段。
    private static func dropLostSession(_ ctx: IMEngineContext,
                                        nowMS: Int64) -> IMMachineOutput<IMEngineContext> {
        let room = IMRoomMachine.resume(ctx.room, resumed: false)
        var emit = room.emit
        var call = ctx.call

        if ctx.call.state != .idle {
            // 不变量 I8 的那个唯一例外：服务端的 call.ended 送不到，本地合成一条。
            let synthesized = IMCallMachine.synthesizeNetworkEnd(ctx.call, nowMS: nowMS)
            call = synthesized.state
            emit.append(contentsOf: synthesized.emit)
        } else if ctx.room.state != .idle {
            emit.append(IMEmittedEvent("onRoomLeft", ["room_id": .string(ctx.room.roomID)]))
        }

        var next = ctx
        next.room = room.state
        next.call = call
        return IMMachineOutput(next, send: room.send, emit: emit)
    }

    private static func handleInternal(_ ctx: IMEngineContext,
                                       _ name: String,
                                       nowMS: Int64) -> IMMachineOutput<IMEngineContext> {
        /*
         **服务端那一侧已经不可能再恢复这条会话了**（§1.4 的恢复窗口过了）。

         语义与「重连上了但 `resumed == false`」完全一样，所以走同一段代码：房间归零、
         通话本地合成一条 `ended{network}`。差别只在**不必等重连成功**——
         网络一直不回来的话那一刻永远不会到，界面就永远停在「正在重连」、
         连挂断都点不动（真机 2026-09-08 的 iOS carol）。

         「什么时候算过了窗口」由连接层算（只有它知道心跳周期），
         见 `IMSignalConnection` 的 `giveUpDelayMS`。
         */
        if name == "session_unrecoverable" {
            return dropLostSession(ctx, nowMS: nowMS)
        }
        if name == "ws_closed_4403" {
            // 被踢：什么都不留。重连没有意义——那等于跟另一台设备打架。
            var next = IMEngineContext()
            next.room = IMRoomMachine.cleared(.idle)
            // **不带关闭码**：这个内部事件也被「鉴权连续失败」复用（那时真实关闭码是
            // 4401），写死 4403 就是在撒谎。关闭码由连接层原样上报——
            // 状态机这一份 onDisconnected 只用来驱动状态迁移，门面不会外发它。
            return IMMachineOutput(next, emit: [
                IMEmittedEvent("onKickedOut"),
                IMEmittedEvent("onDisconnected"),
            ])
        }
        // 进房 / 离房被服务端拒了：两条都只关房间机的事，原样转交。
        // **leave_failed 少接一条的代价见 IMRoomMachine 那一支**——媒体停不掉、房也再进不去。
        if name == "join_failed" || name == "leave_failed" {
            let room = IMRoomMachine.reduce(ctx.room, .internalEvent(name: name))
            var next = ctx
            next.room = room.state
            return IMMachineOutput(next, send: room.send, emit: room.emit)
        }
        if name == "call_failed" {
            // 交给通话机回 idle；它抛的 onCallEnd 会顺带把房间也清掉（见 liftCall）。
            return liftCall(ctx, IMCallMachine.reduce(ctx.call, .internalEvent(name: name)))
        }
        if name == "disconnected" {
            let room = IMRoomMachine.reduce(ctx.room, .internalEvent(name: name))
            var next = ctx
            next.room = room.state
            return IMMachineOutput(next, emit: [IMEmittedEvent("onDisconnected")] + room.emit)
        }
        // 其余内部事件（media_ready）交给通话机。
        let call = IMCallMachine.reduce(ctx.call, .internalEvent(name: name))
        var next = ctx
        next.call = call.state
        return IMMachineOutput(next, send: call.send, emit: call.emit)
    }

    private static func routeFrame(_ ctx: IMEngineContext, type: String,
                                   data: [String: IMJSON]) -> IMMachineOutput<IMEngineContext> {
        if type.hasPrefix("call.") {
            return liftCall(ctx, IMCallMachine.reduce(ctx.call, .recv(type: type, data: data)))
        }
        if type.hasPrefix("room.") {
            let room = IMRoomMachine.reduce(ctx.room, .recv(type: type, data: data))
            var next = ctx
            next.room = room.state
            return IMMachineOutput(next, send: room.send, emit: room.emit)
        }
        return IMMachineOutput(ctx)
    }

    private static func routeAct(_ ctx: IMEngineContext, op: String,
                                 args: [String: IMJSON]) -> IMMachineOutput<IMEngineContext> {
        if callActs.contains(op) {
            return liftCall(ctx, IMCallMachine.reduce(ctx.call, .act(op: op, args: args)))
        }
        if roomActs.contains(op) {
            let room = IMRoomMachine.reduce(ctx.room, .act(op: op, args: args))
            var next = ctx
            next.room = room.state
            return IMMachineOutput(next, send: room.send, emit: room.emit)
        }
        return IMMachineOutput(ctx)
    }

    /// liftCall 把通话机的输出抬到 engine 层，并**把 room.join 转交给房间机**。
    ///
    /// 不做这一步的话，房间机不知道自己正在进房，随后的 room.join.ok 就没人接，
    /// UI 会停在「接通中」不动。
    private static func liftCall(_ ctx: IMEngineContext,
                                 _ result: IMMachineOutput<IMCallContext>)
        -> IMMachineOutput<IMEngineContext> {
        var send: [IMOutgoingFrame] = []
        var emit = result.emit
        var room = ctx.room

        for frame in result.send {
            guard frame.type == IMFrameType.roomJoin else {
                send.append(frame)
                continue
            }
            let joined = IMRoomMachine.reduce(room, .act(op: "join", args: [
                "room_id": frame.data["room_id"] ?? .string(""),
                "room_token": frame.data["room_token"] ?? .string(""),
            ]))
            room = joined.state
            send.append(contentsOf: joined.send)
            emit.append(contentsOf: joined.emit)
        }

        // 通话结束 = 房间没了。服务端在发出 call.ended 的同时就销毁了房间（§4.4），
        // 所以这里只是**本地归零**，不发 room.leave——那一帧只会换回一个 1201。
        // 也不补抛 onRoomLeft：onCallEnd 是所有结束分支的唯一出口（§7.5），
        // 为同一件事抛两个回调会让宿主的记账重复。
        if emit.contains(where: { $0.callback == "onCallEnd" }) {
            room = IMRoomMachine.cleared(.idle)
        }

        var next = IMEngineContext()
        next.room = room
        next.call = result.state
        return IMMachineOutput(next, send: send, emit: emit)
    }
}
