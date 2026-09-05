import Foundation

/*
 Engine 的**核心循环**：输入喂进状态机 → 产出的帧发出去 → 应答再喂回来。

 从门面拆出来的理由：门面负责的是**对宿主的那张 API 表**，
 这里负责的是**状态机与线路之间的往返**。状态机的当前快照也归这里管——
 它是这个循环的状态，不是门面的字段。（Web 端同一刀切在同一处：`frameLoop.ts`。）

 用 `actor` 而不是队列 + 锁：状态机快照是唯一的可变共享状态，
 actor 让「谁能改它」在类型系统里就说清楚了（CONVENTIONS §5 优先用 actor）。
 */
actor IMFrameLoop {
    /// 状态机的当前快照。**只有这个 actor 能改它**。
    private(set) var ctx = IMEngineContext()

    private let sender: IMFrameSender
    private let dispatcher: IMEventDispatcher
    private let media: IMMediaAdapter?
    /// 取成闭包：连接会随重连换对象。
    private let connection: @Sendable () -> IMSignalConnection?

    init(sender: IMFrameSender, dispatcher: IMEventDispatcher, media: IMMediaAdapter?,
         connection: @escaping @Sendable () -> IMSignalConnection?) {
        self.sender = sender
        self.dispatcher = dispatcher
        self.media = media
        self.connection = connection
    }

    /// reset 把状态机归零（logout 用）。
    func reset() {
        ctx = IMEngineContext()
    }

    /**
     handleIncoming 是**所有下行帧的唯一入口**——事件与应答都走它。

     `room.ice_candidate` 不进状态机：候选只关媒体层的事。
     `room.answer(pub)` 要**先把 SDP 应用到媒体层再推进状态机**，
     否则状态机说「已发布」的时候上行其实还没协商完。
     */
    func handleIncoming(_ type: String, _ data: [String: IMJSON]) async {
        if type == IMFrameType.roomICECandidate {
            await addRemoteCandidate(data)
            return
        }
        let pc = data["pc"]?.stringValue ?? ""
        if type == IMFrameType.roomOffer, pc == IMPCRole.sub.wireValue {
            await sender.noteSubOffer(data["sdp"]?.stringValue ?? "")
        }
        if type == IMFrameType.roomAnswer, pc == IMPCRole.pub.wireValue, let media {
            do {
                try await media.applyPubAnswer(data["sdp"]?.stringValue ?? "")
            } catch {
                emitError(error)
            }
        }
        await dispatch(.recv(type: type, data: data))
    }

    /// dispatch 把一个输入喂进状态机，然后抛事件、发帧。
    func dispatch(_ input: IMMachineInput) async {
        let result = IMEngineMachine.reduce(ctx, input)
        ctx = result.state

        // **一通结束就把媒体面归零**，而且在抛事件之前：宿主收到 callDidEnd 时
        // Engine 已经是干净的，下一通不会带着上一通的 PeerConnection。
        if result.emit.contains(where: { Self.leaveCallbacks.contains($0.callback) }) {
            media?.close()
        }

        /*
         **先抛事件、再发帧**，顺序不能反。

         事件说的是「刚刚发生了什么」，帧说的是「接下来要做什么」。反过来的话，
         帧的应答会在本轮事件之前被处理掉，宿主收到的回调顺序就乱了。
         Web 端实测过的症状：`call.connected` 产出 onCallBegin（事件）与
         room.join（帧），先发帧的话 join.ok 立刻回来并抛出 onRoomJoined，
         于是宿主看到的是 **roomJoined / userEnter 排在 callBegin 前面**——
         它还没被告知有这通电话，就先收到了这通电话房间里的事件。
         */
        logLocalReject(input, result.emit)
        for event in result.emit {
            /*
             **`onDisconnected` 由连接层独占**，状态机那一份不外发。

             两边都发的话宿主每次断线收到两条，而且状态机那条是空载荷的
             （一致性向量里就是 `args: {}`——关闭码不是状态机的事）。
             更糟的是「鉴权连续失败」复用了 `ws_closed_4403` 这个内部事件，
             状态机那条要是带上码就会是一个**假的 4403**。
             */
            if event.callback == "onDisconnected" { continue }
            dispatcher.emit(event)
        }
        for frame in result.send {
            await sendFrame(frame)
        }
    }

    /// sendFrame 发一帧，并把应答喂回状态机。
    private func sendFrame(_ frame: IMOutgoingFrame) async {
        guard let connection = connection() else { return }
        do {
            guard let reply = try await sender.send(connection, frame) else { return }
            // **应答也要喂回状态机**：join.ok / publish.ok 都是状态推进的关键一步。
            await handleIncoming(reply.envelope.type, reply.data)
        } catch {
            // 请求失败不该中断整个事件流：转成 error 事件交给宿主。
            emitError(error)
            /*
             **进房失败要把房间状态退回 idle**。

             不退的话状态机永远停在 `joining`，之后每一次 publish 都会被不变量 R1
             本地拒成 2005，而宿主只看到两条没头没尾的 2005——真正的原因
             （那条 room.join 被服务端拒了）已经淹在上一条 error 里了。
             退回 idle 至少让「重进一次」成为可能。
             */
            if frame.type == IMFrameType.roomJoin {
                await dispatch(.internalEvent(name: "join_failed"))
            }
            /*
             同理，**发起呼叫被拒也要退回 idle**。不退的话界面停在「正在呼叫…」，
             而服务端根本没有这通电话，之后每次挂断都换回 1401 call_not_found，
             用户永远退不出那一屏。
            */
            if frame.type == IMFrameType.callInvite {
                await dispatch(.internalEvent(name: "call_failed"))
            }
        }
    }

    /// sendCandidate 把本端候选发上去。候选是尽力而为的，失败只报不中断。
    func sendCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async {
        guard let connection = connection() else { return }
        do {
            try await sender.sendCandidate(connection, pc, candidate)
        } catch {
            emitError(error)
        }
    }

    /// uidOf 查某条下行轨道属于谁；不知道时返回空串。
    func uidOf(_ trackID: String) -> String {
        ctx.room.remoteTracks[trackID]?.uid ?? ""
    }

    /**
     addRemoteCandidate 把服务端来的候选交给媒体层。

     **Web 端一开始把这条路整条漏了**：候选只往上发、不往下收，于是下行连接
     能不能建立全看运气——服务端的 SDP 里碰巧带上主机候选就通，
     没带上（进房即订阅时协商得早，服务端还没收集完）就永远停在 `new`，
     界面上是「格子在、画面黑」，而且不报任何错。三方会议必现。
     */
    private func addRemoteCandidate(_ data: [String: IMJSON]) async {
        let raw = data["candidate"]?.stringValue ?? ""
        guard !raw.isEmpty else { return } // 空候选 = 收集结束，协议要求容忍（§3.3）
        guard let media else { return }
        let pc: IMPCRole = (data["pc"]?.stringValue ?? "") == IMPCRole.pub.wireValue ? .pub : .sub
        let candidate = IMICECandidate(candidate: raw,
                                       sdpMid: data["sdp_mid"]?.stringValue ?? "",
                                       sdpMLineIndex: Int(data["sdp_mline_index"]?.intValue ?? 0))
        do {
            try await media.addRemoteCandidate(pc, candidate)
        } catch {
            // 乱序候选是常态（§3.3 要求容忍）：转成 error 事件，不中断事件流。
            emitError(error)
        }
    }

    private func emitError(_ error: Error) {
        let rtc = error as? IMRTCError ?? IMRTCError(.internalError, String(describing: error))
        dispatcher.emit(IMEmittedEvent("onError", [
            "code": .int(Int64(rtc.code.rawValue)),
            "name": .string(rtc.code.name),
        ]))
    }

    /**
     logLocalReject 把「状态机本地拒掉了一个动作」记成一条**说得清的**日志。

     宿主收到的 onError 只有 `code=2005 / invalid_state`——**哪个动作、当时什么状态，
     一个字都没有**。Web 端三人会议那次排查就卡在这里：日志里十几条一模一样的 2005，
     要读代码才能推出「点的是挂断，而会议房里没有 call」。

     不把这些塞进 onError 的载荷，是因为那是四端共用的公开回调表；诊断信息进日志就够了。
     */
    private func logLocalReject(_ input: IMMachineInput, _ emit: [IMEmittedEvent]) {
        guard case let .act(op, _) = input else { return }
        let rejected = emit.contains {
            $0.callback == "onError"
                && $0.args["code"]?.intValue == Int64(IMErrorCode.invalidState.rawValue)
        }
        guard rejected else { return }
        IMRTCLog.warn("动作被状态机本地拒绝", [
            "op": op,
            "call_state": ctx.call.state.rawValue,
            "room_state": ctx.room.state.rawValue,
        ])
    }

    /// leaveCallbacks 是「这一轮媒体到此为止」的信号。
    ///
    /// 三个都要算：通话正常结束、自己离房、房间被服务端关掉。
    /// 少算一个的后果是同一条：下一次进房带着上一轮的 PeerConnection。
    private static let leaveCallbacks: Set<String> = ["onCallEnd", "onRoomLeft", "onRoomClosed"]
}
