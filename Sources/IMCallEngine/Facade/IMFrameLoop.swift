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

    /// 状态的只读镜像，给进不了 actor 的 `IMCallEngine.forceEnd()` 同步读（见 `IMContextMirror`）。
    nonisolated let mirror = IMContextMirror()

    /// reset 把状态机归零（logout 用）。
    func reset() {
        ctx = IMEngineContext()
        mirror.set(ctx)
    }

    /// ping 什么都不做：卡顿探针拿它量「帧循环 actor 此刻排不排得上号」（见 `IMStallProbe`）。
    func ping() {}

    /**
     handleIncoming 是**所有下行帧的唯一入口**——事件与应答都走它。

     `room.ice_candidate` 不进状态机：候选只关媒体层的事。
     `room.answer(pub)` 要**先把 SDP 应用到媒体层再推进状态机**，
     否则状态机说「已发布」的时候上行其实还没协商完。
     */
    /// 上行协商闸门：一条 pub PC 上同一时刻只许一个 offer 在飞。见 `IMPubOfferGate`。
    private var pubOffer = IMPubOfferGate()

    /**
     放开上行协商闸门。**会话恢复与通话结束都要调**。

     换了一条连接，之前那个 offer 的 answer 永远不会回来了；不放的话闸门一直关着，
     恢复后的重新协商只会排队，那条 PC 就此永久沉默（Android 上真机撞到过）。
     */
    func resetPubNegotiation() {
        pubOffer.reset()
    }

    /// 交给媒体层之前要先看房间还在不在的那几帧。见 `handleIncoming` 开头。
    private static let mediaFrames: Set<String> = [
        IMFrameType.roomICECandidate, IMFrameType.roomOffer, IMFrameType.roomAnswer,
    ]

    func handleIncoming(_ type: String, _ data: [String: IMJSON]) async {
        /*
         **房间已经不在了，迟到的媒体帧不许把 PeerConnection 重新建起来。**

         媒体层的 `ensurePeers()` 见不到现成的 PC 就现造一对——强制收场、通话结束之后
         才到的候选或 SDP 要是照常交下去，就会在一个没人要的房间上凭空长出两条 PC，
         一直挂到下一次关媒体。状态机那一侧由 `IMRoomMachine` 的 idle 分支丢弃。
        */
        if ctx.room.state == .idle, Self.mediaFrames.contains(type) {
            IMRTCLog.debug("房间已不在，丢弃迟到的媒体帧", ["type": type])
            return
        }
        if type == IMFrameType.roomICECandidate {
            await addRemoteCandidate(data)
            return
        }
        let pc = data["pc"]?.stringValue ?? ""
        if type == IMFrameType.roomOffer, pc == IMPCRole.sub.wireValue {
            await sender.noteSubOffer(data["sdp"]?.stringValue ?? "")
        }
        if type == IMFrameType.roomAnswer, pc == IMPCRole.pub.wireValue, let media {
            var owesAnother = false
            do {
                try await media.applyPubAnswer(data["sdp"]?.stringValue ?? "")
                owesAnother = pubOffer.finish()
            } catch {
                // **失败也要放闸**：少放一处就是永久卡死，而且一条错误都没有。
                pubOffer.abort()
                emitError(error)
            }
            await dispatch(.recv(type: type, data: data))
            // 排队的那一个补在**状态机吃过这条 answer 之后**——早了的话新 offer
            // 会撞上一个还没收工的房间状态。
            if owesAnother {
                IMRTCLog.info("上行补一次协商（上一轮在飞时排下的）", [:])
                await dispatch(.act(op: "restart_pub_ice"))
            }
            return
        }
        await dispatch(.recv(type: type, data: data))
    }

    /**
     dispatch 把一个**找不到调用方**的输入喂进状态机（下行帧、内部事件、引擎自发的动作如
     `restart_pub_ice`），然后抛事件、发帧。**永不 throw**：帧失败转成 `onError`；
     本地拒绝只记日志（`logLocalReject`）。
     */
    func dispatch(_ input: IMMachineInput) async {
        let result = IMEngineMachine.reduce(ctx, input)
        logLocalReject(input, result)
        await apply(result, settlement: nil)
    }

    /**
     request 把一次**宿主调用**喂进状态机，并把结果交回调用方（server `docs/design/ACTION_RESULT_DESIGN.md` R1）。

     - 状态机就地拒绝 → throw 那个码（`2005`），不抛事件、不发帧；
     - 本步直接产出的帧被拒 / 超时 / 没连接 / 等应答时断线 → throw 那个错误（带 `forType`），
       **不再**发 `onError`（R3）；回滚照做，`onCallEnd(error)` 之类的状态事件**先于** throw 发出（R4）；
     - 否则返回最后一帧应答的 data（`call` 从里面取 `call_id`）。本步没发帧（意图被缓存、
       拨出中挂起的 cancel）时返回空字典：调用已受理，之后的连锁帧失败走 `onError`（R2）。
     */
    func request(_ input: IMMachineInput) async throws -> [String: IMJSON] {
        let result = IMEngineMachine.reduce(ctx, input)
        logLocalReject(input, result)
        let settlement = IMSettlement()
        await apply(result, settlement: settlement)
        if let code = result.reject {
            throw IMRTCError(code, "状态机在 call=\(ctx.call.state.rawValue) room=\(ctx.room.state.rawValue) 时拒绝了 \(Self.opName(input))")
        }
        if let error = settlement.error { throw error }
        return settlement.reply
    }

    private static func opName(_ input: IMMachineInput) -> String {
        guard case let .act(op, _) = input else { return "" }
        return op
    }

    /**
     forceEnd 在本地收掉门面那边已经发过结束帧的那一场（`IMCallEngine.forceEnd()`）。

     **只收门面看到的那一场**：门面读的是镜像，可能比这里晚一拍。这一拍里那通电话要是已经
     正常结束、甚至又来了一通新的，照着现在的状态收场就会把新来的那通一声不响地吞掉。
     所以先比对 call_id 与 room_id，对不上就什么都不做。

     结束帧**一般不在这里再发一遍**：门面已经直接交给信令连接了。唯一的例外是拨出中——
     门面读镜像那一刻 `call.invite.ok` 还没回来、手里没有 call_id，什么都没发出去；
     这一拍里它回来了（还在 inviting、call_id 已经有了），那就是同一场，cancel 由这里补上。
     再晚一点回来的（本地已经 idle）由通话机的 idle 分支补（`IMCallMachine.handleLateFrame`）。
     */
    func forceEnd(callID: String, roomID: String) async {
        let inviteLanded = callID.isEmpty && ctx.call.state == .inviting && !ctx.call.callID.isEmpty
        guard inviteLanded || (ctx.call.callID == callID && ctx.room.roomID == roomID) else {
            IMRTCLog.info("强制收场落地时那一场已经不在了，跳过本地收场",
                          ["call_id": callID, "room_id": roomID])
            return
        }
        let ended = IMEngineMachine.forceEnd(ctx)
        await apply(IMMachineOutput(ended.state, send: inviteLanded ? ended.send : [], emit: ended.emit),
                    settlement: nil)
    }

    /// apply 把一次推进的结果落地：记状态、同步媒体层、抛事件、发帧。
    ///
    /// `settlement` 不为 nil 时本步是宿主调用，产出的帧的结果记进去交给调用方（见 `request`）。
    private func apply(_ result: IMMachineOutput<IMEngineContext>, settlement: IMSettlement?) async {
        land(result)
        for frame in result.send {
            await sendFrame(frame, settlement: settlement)
        }
    }

    /// land 是 `apply` 里**不等待**的那一半：记状态、同步媒体层、抛事件。帧另发。
    private func land(_ result: IMMachineOutput<IMEngineContext>) {
        ctx = result.state
        mirror.set(ctx)

        // 每推进一步就把「哪条轨道是谁的」同步给媒体层。**轨道与归属谁先到都可能**，
        // 所以这一步不能只在 track_published 那一支上做（Web 端同一处：`frameLoop.ts`）。
        media?.claimRemoteTracks(ctx.room.remoteTracks.mapValues(\.uid))

        // **一通结束就把媒体面归零**，而且在抛事件之前：宿主收到 callDidEnd 时
        // Engine 已经是干净的，下一通不会带着上一通的 PeerConnection。
        if result.emit.contains(where: { Self.leaveCallbacks.contains($0.callback) }) {
            media?.close()
            // PC 都关了，在飞的那个 offer 的 answer 永远不会来——不归零的话
            // 下一通电话的第一个 offer 就会被闸门挡在门外。
            pubOffer.reset()
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
        for event in result.emit {
            /*
             **`onDisconnected` 由连接层独占**，状态机那一份不外发。

             两边都发的话宿主每次断线收到两条，而且状态机那条是空载荷的
             （一致性向量里就是 `args: {}`——关闭码不是状态机的事）。
             更糟的是「鉴权连续失败」复用了 `ws_closed_4403` 这个内部事件，
             状态机那条要是带上码就会是一个**假的 4403**。
             */
            if event.callback == IMEmittedCallbackName.onDisconnected { continue }
            /*
             **`onKickedOut` 同理由连接层独占。**

             状态机那一份不带原因，而宿主真正需要的是**为什么被踢**：`.takenOver`
             （被顶号/被吊销，回登录页）与 `.authExpired`（票的问题，换票重来）处置相反。
             状态机不可能知道这个——它只收到一个 `ws_closed_4403` 内部事件，
             而「鉴权失败到顶」也复用了同一个内部事件。两边都发的话宿主会收到两条，
             其中一条还没有 reason。（Web 端就是在这里踩了双抛。）
            */
            if event.callback == IMEmittedCallbackName.onKickedOut { continue }
            dispatcher.emit(event)
        }
    }

    /**
     sendFrame 发一帧，并把应答喂回状态机。

     `settlement` 不为 nil 时这一帧是宿主调用直接发出的：失败记进去交给调用方，不发 `onError`。
     同一次调用发了几帧的，调用方拿第一个失败，其余的照旧走 `onError`——一个错误只报一次。
     */
    private func sendFrame(_ frame: IMOutgoingFrame, settlement: IMSettlement?) async {
        /*
         **没有连接不是「什么都不做」，是一次失败。**

         原先这里是裸的 `guard let connection = connection() else { return }`：状态机已经
         迁移过了，帧却没发出去，既不回滚也不报错。宿主在 `login()` 之前（或 `logout()`
         之后）调一次 `call()`，通话机就永久停在 `.inviting`——界面「正在呼叫…」转个不停，
         之后 `hangup()` 被本地拒成 2005、`cancel()` 产出的帧同样被丢掉，**再也回不到
         idle**，下一通真电话也被 2005 挡住。走下面这条收场路径之后，宿主拿到的是一条
         `2007 not_logged_in` 加一次正常的 `onCallEnd`，界面收得掉。
         （Android 的 `IMSignalConnection.request` 未连接时就是立刻回 `NOT_LOGGED_IN`；
         Web 的 `frameLoop.sendFrame` 同日补上。）
         */
        guard let connection = connection() else {
            settleFailure(IMRTCError(.notLoggedIn, "\(frame.type)：信令未连接", forType: frame.type), settlement)
            await rollback(frame)
            return
        }
        let isPubOffer = frame.type == IMFrameType.roomOffer
            && frame.data["pc"]?.stringValue == IMPCRole.pub.wireValue
        if isPubOffer, !pubOffer.begin() {
            IMRTCLog.debug("pub 协商进行中，offer 排队", [:])
            return
        }
        let startedNS = DispatchTime.now().uptimeNanoseconds
        let reply: IMRequestResult?
        do {
            reply = try await sender.send(connection, frame)
        } catch {
            Self.noteSlowRequest(frame.type, sinceNS: startedNS, failed: true)
            // **失败也要放闸**（见 IMPubOfferGate）：这一轮的 answer 不会来了。
            if isPubOffer { pubOffer.abort() }
            // 请求失败不该中断整个事件流：交给调用方，找不到调用方就转成 error 事件。
            let rtc = error as? IMRTCError ?? IMRTCError(.internalError, String(describing: error))
            settleFailure(rtc.withForType(frame.type), settlement)
            await rollback(frame)
            return
        }
        Self.noteSlowRequest(frame.type, sinceNS: startedNS, failed: false)
        guard let reply else { return }
        // **应答也要喂回状态机**：join.ok / publish.ok 都是状态推进的关键一步。
        guard let settlement else {
            await handleIncoming(reply.envelope.type, reply.data)
            return
        }
        settlement.reply = reply.data
        await landReplyWithoutWaiting(reply)
    }

    /**
     landReplyWithoutWaiting 是宿主调用直接那一帧的应答：**落进状态机就算结算完**，不等它连锁出来的帧（R2 / D1）。

     状态与事件在这里当场落地；之后的连锁帧（publish.ok → pub offer → 等 answer，join.ok → 重放缓存的发布）
     放进一个新 Task 发，它们有自己的出口（`onError`）。等它们的话，`publishMicrophone()` 要陪着 SDP 协商走完，
     协商卡住还得多等一个请求超时——而那些失败本来就不算这次调用的。（Web 端同一处：`frameLoop.ts` 的 `sendFrame`。）

     `room.answer` 这类要先交给媒体层的应答照旧走 `handleIncoming` 等它走完（宿主调用发不出 pub offer，走不到这里）。
     */
    private func landReplyWithoutWaiting(_ reply: IMRequestResult) async {
        let type = reply.envelope.type
        guard !Self.mediaFrames.contains(type) else {
            await handleIncoming(type, reply.data)
            return
        }
        let result = IMEngineMachine.reduce(ctx, .recv(type: type, data: reply.data))
        land(result)
        guard !result.send.isEmpty else { return }
        Task {
            for frame in result.send {
                await self.sendFrame(frame, settlement: nil)
            }
        }
    }

    /// settleFailure 把一帧的失败交给调用方；没有调用方、或调用方已经拿到一个失败时发 `onError`。
    private func settleFailure(_ error: IMRTCError, _ settlement: IMSettlement?) {
        if let settlement, settlement.error == nil {
            settlement.error = error
            return
        }
        emitError(error)
    }

    /// 请求往返超过这么久记一条。正常是几十毫秒。
    private static let slowRequestMS: UInt64 = 2_000

    /**
     noteSlowRequest 记下「这一帧从交给 sender 到拿回应答」慢得不正常的那几次。

     2026-09-13 14:53 frank 的 room.join 从状态机产出到服务端收到隔了 28.6 秒，而本端一个字都没留下。
     有了这一条，拿它的 `elapsed_ms` 对服务端的受理时刻，就分得清慢在本端发出之前还是服务端那边。
     */
    private static func noteSlowRequest(_ type: String, sinceNS: UInt64, failed: Bool) {
        let elapsedMS = (DispatchTime.now().uptimeNanoseconds - sinceNS) / 1_000_000
        guard elapsedMS >= slowRequestMS else { return }
        IMRTCLog.warn("请求往返慢", ["type": type, "elapsed_ms": String(elapsedMS), "failed": String(failed)])
    }

    /// rollback 把「这一帧没送到」翻译成状态机能收场的内部事件。
    ///
    /// **一张表管住所有中间态**：留在中间态的代价永远是同一种——界面停在一个转圈的屏上，
    /// 而之后每一个动作都被不变量本地拒成 2005，宿主只看到一串没头没尾的 2005，
    /// 真正的原因早淹在上一条 error 里了。四端同一张表
    /// （Android 的 `IMCallEngine.onRequestFailed`、Web 的 `frameLoop.rollback`）。
    private func rollback(_ frame: IMOutgoingFrame) async {
        let type = frame.type
        /*
         **进房失败要把房间状态退回 idle**。

         不退的话状态机永远停在 `joining`，之后每一次 publish 都会被不变量 R1
         本地拒成 2005，而宿主只看到两条没头没尾的 2005——真正的原因
         （那条 room.join 被服务端拒了）已经淹在上一条 error 里了。
         退回 idle 至少让「重进一次」成为可能。
         */
        if type == IMFrameType.roomJoin {
            await dispatch(.internalEvent(name: "join_failed"))
        }
        /*
         **离房被拒也要退回 idle**，这是 join_failed 的镜像，漏掉它的代价更大。

         `room.leave` 会被拒是真事：服务端在「会话已不在房间里」时回 1203
         （两人同时离房、或房间刚被「已空，已关闭」销毁掉，都撞得上）。
         而被拒的语义恰恰是**我们已经不在房里了**，本地却还停在 leaving：
         `leaveCallbacks` 一个都不会抛，于是 `media.close()` 永远不调用
         （摄像头、麦克风一直开着），再点离房被 R1 拒成 2005，
         再 join 也因为「不在 idle」被拒——除非 logout，这台 Engine 永远进不了房。
         （Android 的 `IMCallEngine.onRequestFailed` 一直接着这一条。）
        */
        if type == IMFrameType.roomLeave {
            await dispatch(.internalEvent(name: "leave_failed"))
            /*
             等应答期间断线的话，房间机先收到 `disconnected` 从 `leaving` 进了 `reconnecting`，
             `leave_failed` 就不认了——恢复之后人又回到房里，而宿主早就按了离开。
             这一帧只可能是宿主要离房才发的，没有通话时照样本地收场（ACTION_RESULT_DESIGN D2）。
             */
            if ctx.call.state == .idle { await endLocally() }
            return
        }
        /*
         **退出类被拒也要本地收场**（ACTION_RESULT_DESIGN D2）：用户按的是「结束」，服务端拒了
         （最常见的是通话已经结束 1402 / 1401）或根本没发出去，都不该让界面停在通话里。
         结束帧已经试过了，这里只落本地——与 `forceEnd` 同一份收场计算，只是不再发帧。
         */
        if Self.exitFrames.contains(type) {
            await endLocally()
            return
        }
        /*
         同理，**通话类请求被拒也要退回 idle**。不退的话界面停在「正在呼叫…」，
         而服务端根本没有这通电话，之后每次挂断都换回 1401 call_not_found，
         用户永远退不出那一屏。

         **三帧都要接，不只是 invite。** `call.accept` 被拒（主叫刚取消，
         服务端回 1401/1405）时通话机永久停在 `accepting`：onCallEnd 不抛、
         来电页收不起来，而那时红按钮算出来的是 reject，
         `reduceAct("reject")` 又要求 `ringing`——只换回又一个 2005，
         用户除了杀进程出不去。`call.join` 同理。
         （Android 的 onRequestFailed 一直是 INVITE / ACCEPT / JOIN 三个一起接的。）
        */
        if Self.callFailFrames.contains(type) {
            await dispatch(.internalEvent(name: "call_failed"))
        }
        /*
         **发布被拒：通话里直接收掉整通（reason=error），没有通话才只回滚那一条**（静默失败审计 §A）。

         原先这张表不认 `room.publish`，那条轨道永远停在 `publishing`：`publish.ok` 不来 →
         pub offer 永远不产出 → 上行从未协商。界面显示已接通、计时器在走、按钮显示没静音，
         **对方全程听不见看不见，零提示**。留在通话里只报错也不够——Kit 并不展示这类错误，
         而服务端会拒的几种情形（房间已不在、同一路重复发布、请求超时）重试都救不回来。
         收场走 forceEnd：挂断帧不排队、onCallEnd 只抛一次，Kit 本来就认它（Web 端同一份推理：`frameLoop.ts`）。
         */
        if type == IMFrameType.roomPublish {
            if ctx.call.state != .idle {
                IMRTCLog.warn("发布被拒，结束本端通话", ["call_id": ctx.call.callID])
                await forceEndForPublishFailure()
                return
            }
            await dispatch(.internalEvent(name: "publish_failed", args: ["cid": frame.data["cid"] ?? .string("")]))
            return
        }
        // 订阅被拒只摘记账，不收场：最常见的 1301 是订阅与对方停推赛跑输了，通话本身没事。
        if type == IMFrameType.roomSubscribe {
            await dispatch(.internalEvent(name: "subscribe_failed",
                                          args: ["track_id": frame.data["track_id"] ?? .string("")]))
        }
    }

    /**
     forceEndForPublishFailure 是 `room.publish` 在通话里被拒时的收场路径。

     与门面的 `IMCallEngine.forceEnd()` 同一个形状（结束帧直发、本地立刻收场），但**不经过
     mirror 也不需要 call_id/room_id 比对**——这里已经在 actor 内部，`ctx` 就是此刻的真实状态，
     没有跨 actor 的那一拍延迟。`reason` 写死 `.error`：这不是用户按的红键，写成 hangup 是撒谎。
     */
    private func forceEndForPublishFailure() async {
        let ended = IMEngineMachine.forceEnd(ctx, reason: .error)
        guard !ended.emit.isEmpty else { return }
        if let connection = connection() {
            for frame in ended.send {
                connection.fire(frame.type, data: IMFrameSender.wireData(frame) ?? frame.data)
            }
        } else if !ended.send.isEmpty {
            IMRTCLog.warn("发布被拒收场：没有信令连接，结束帧发不出去，只做本地收场", [:])
        }
        await apply(IMMachineOutput(ended.state, send: [], emit: ended.emit), settlement: nil)
    }

    /// endLocally 按此刻状态本地收场（通话或会议），不发帧。已经收干净时什么都不做。
    private func endLocally() async {
        let ended = IMEngineMachine.forceEnd(ctx)
        guard !ended.emit.isEmpty else { return }
        IMRTCLog.warn("结束帧失败，本地收场", ["call_id": ctx.call.callID, "room_id": ctx.room.roomID])
        await apply(IMMachineOutput(ended.state, send: [], emit: ended.emit), settlement: nil)
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
        dispatcher.emit(IMEmittedEvent.error(rtc))
    }

    /**
     logLocalReject 把「状态机本地拒掉了一个动作」记成一条**说得清的**日志。

     宿主拿到的错误只有 `code=2005 / invalid_state`——**哪个动作、当时什么状态，
     一个字都没有**。Web 端三人会议那次排查就卡在这里：日志里十几条一模一样的 2005，
     要读代码才能推出「点的是挂断，而会议房里没有 call」。
     引擎自己发起的动作（`restart_pub_ice`）被拒时**只有**这一条日志。
     */
    private func logLocalReject(_ input: IMMachineInput, _ result: IMMachineOutput<IMEngineContext>) {
        guard case let .act(op, _) = input, result.reject != nil else { return }
        IMRTCLog.warn("动作被状态机本地拒绝", [
            "op": op,
            "call_state": ctx.call.state.rawValue,
            "room_state": ctx.room.state.rawValue,
        ])
    }

    /// callFailFrames 是「这一帧被拒 = 这通电话没建立起来」的那几帧。
    ///
    /// 少接一帧的后果都一样：通话机停在中间态，界面收不起来，
    /// 而红按钮在那个状态下算出的动作又会被本地拒成 2005。
    private static let callFailFrames: Set<String> = [
        IMFrameType.callInvite, IMFrameType.callAccept, IMFrameType.callJoin,
    ]

    /// exitFrames 是「这一帧失败了也要本地收场」的结束帧（`room.leave` 单独处理，见 `rollback`）。
    private static let exitFrames: Set<String> = [
        IMFrameType.callHangup, IMFrameType.callReject, IMFrameType.callCancel,
    ]

    /// leaveCallbacks 是「这一轮媒体到此为止」的信号。
    ///
    /// 三个都要算：通话正常结束、自己离房、房间被服务端关掉。
    /// 少算一个的后果是同一条：下一次进房带着上一轮的 PeerConnection。
    private static let leaveCallbacks: Set<String> = ["onCallEnd", "onRoomLeft", "onRoomClosed"]
}

/**
 IMSettlement 收集**一次宿主调用直接发出的那几帧**的结算（ACTION_RESULT_DESIGN R1 / R2）。

 只有 `IMFrameLoop.request` 会建它，只在帧循环 actor 里读写；应答处理里连锁出来的帧不带它，
 失败照旧发 `onError`——那些失败找不到调用方。
 */
final class IMSettlement {
    var error: IMRTCError?
    var reply: [String: IMJSON] = [:]
}
