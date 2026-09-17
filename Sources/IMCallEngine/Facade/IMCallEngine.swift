import Foundation

/*
 门面：把信令连接、状态机、媒体适配器接在一起。**宿主唯一需要接触的类型。**

 # 它自己不做决策

 「现在能不能 accept」「该不该抛 onCallEnd」全在状态机里（那是纯逻辑，跑一致性向量）；
 「SDP 长什么样」全在媒体适配器里。门面只做三件事：
 **路由输入、把机器产出的帧交给 sender、把事件交给 dispatcher**。

 # 两种集成方式都从这里进

 · 只要 SDK、UI 自己画 → 用 `IMCallEngineDelegate`（= 设计文档 §7.5 的回调总表），
   连媒体适配器都可以不传：登录、振铃、成员进出、静音通知一个都不少。
 · 要整套界面 → 用 `IMCallKit`，它也只消费这同一张表，没有私有通道。
 */
@objc public final class IMCallEngine: NSObject {

    /// 回调总表的接收方。**weak**（CONVENTIONS §7）。
    @objc public weak var delegate: IMCallEngineDelegate? {
        get { dispatcher.delegate }
        set { dispatcher.delegate = newValue }
    }

    // internal 而不是 private：makeConnection 拆到了 IMCallEngine+Connection.swift。
    let url: URL
    let deviceID: String
    let media: IMMediaAdapter?

    /// internal 而不是 private：媒体回调的接线拆到了 IMCallEngine+MediaEvents.swift。
    lazy var dispatcher = IMEventDispatcher(engine: self)
    private lazy var sender = IMFrameSender(media: media)
    lazy var loop = IMFrameLoop(
        sender: sender, dispatcher: dispatcher, media: media,
        connection: { [weak self] in self?.currentConnection })
    /// 卡顿探针：登录期间盯着主线程、Swift 并发线程池、帧循环三条通道（见 `IMStallProbe`）。
    private lazy var stallProbe: IMStallProbe = {
        let loop = self.loop
        return IMStallProbe(lanes: [
            .init(name: "main") { done in DispatchQueue.main.async { done() } },
            .init(name: "concurrency_pool") { done in Task.detached { done() } },
            .init(name: "frame_loop") { done in Task.detached { await loop.ping(); done() } },
        ])
    }()

    /// connection 归 `stateQueue`。重连不会换 `IMSignalConnection` 对象，
    /// 但 login/logout 会——所以它是可变的。
    private var connection: IMSignalConnection?
    /// 握手拿到的自己的 uid。用来挡「呼叫自己」，也供宿主读。
    /// internal 而不是 private：`onConnected` 的接线拆到了 IMCallEngine+Connection.swift。
    var myUID = ""

    /// 连续这么多次 ICE restart 之后仍判 failed，就认为救不回来了（协议 §7.2）。
    private static let pubIceGiveUp = 3
    /// pub 侧 ICE 自愈的放弃计数。**归 `stateQueue`**——这两个是从 WebRTC 的信令线程改的。
    private var pubIceRestarts = 0
    private var pubIceGaveUp = false
    /// internal 而不是 private：帧泵拆到了 IMCallEngine+FramePump.swift。
    let stateQueue = DispatchQueue(label: "com.imrtc.engine.facade")

    /// `destroy()` 后置真、永不复原。归 `stateQueue`。见 `IMCallEngine+Lifecycle.swift`。
    var isDestroyed = false

    /// 引擎里**这个类型的轨道实际发布了没有**——`publish(_:simulcast:)` 按 `info.kind`
    /// 统一记账，不管这次发布是 `publishMicrophone`/`publishCamera` 直接调的，还是
    /// `openMicrophone`/`openCamera` 触发的，两条路径认的是同一份状态（不会重复发布）。
    /// 不跟 Kit 的 `micCID`/`cameraCID` 共享（Kit 是另一个模块，自己那份是给界面用的）。
    /// 通话结束/离房/房间关闭（init 里挂的内部 observer）与 `logout()` 都会清零。
    /// 归 `stateQueue`。见 `IMCallEngine+MediaSwitches.swift`。
    var publishedMicCID: String?
    var publishedCameraCID: String?

    /// internal 而不是 private：`forceEnd` 拆到了 IMCallEngine+ForceEnd.swift。
    var currentConnection: IMSignalConnection? {
        stateQueue.sync { connection }
    }

    /**
     notePubIceFailure 记一次 pub 侧 ICE 失败，返回「这一次该不该上报 2006」。

     判定与记账在同一次 `sync` 里完成，否则两条信令线程能各自读到 2 再各自加到 3，
     宿主收到两条 2006。
     */
    func notePubIceFailure() -> Bool {
        stateQueue.sync {
            pubIceRestarts += 1
            guard pubIceRestarts >= Self.pubIceGiveUp, !pubIceGaveUp else { return false }
            pubIceGaveUp = true
            return true
        }
    }

    /// resetPubIceGiveUp 在 pub 通了之后清零——那是新一轮，不该拿旧账凑数。
    func resetPubIceGiveUp() {
        stateQueue.sync {
            pubIceRestarts = 0
            pubIceGaveUp = false
        }
    }

    /// emitLocalError 抛一条**本地**错误码（协议 §7.2，永不出现在线路上）。
    func emitLocalError(_ code: IMErrorCode) {
        dispatcher.emit(IMEmittedEvent("onError", [
            "code": .int(Int64(code.rawValue)),
            "name": .string(code.name),
        ]))
    }

    /**
     下行帧的**串行泵**。所有要喂给状态机的东西都从这一条流进去。

     # 为什么不能每帧一个 `Task {}`

     旧实现是 `events.onEvent = { Task { await loop.handleIncoming(...) } }`。
     Task 的**创建**顺序确实是线路顺序（`handleMessage` 跑在信令那条串行队列上），
     但它们没有 actor 隔离，会被丢到全局并发执行器上，**谁先跑到状态机没有保证**。
     反序的后果是实打实的：`participant_joined` 与 `participant_left` 掉个个儿，
     离开先被空房间吃掉、加入再把人放回去，格子里就永远留着一个已经走了的人；
     `call.ringing` 排到 `call.connected` 后面则会被状态机拒成 2005。
     一致性向量抓不到这一类——它是直接喂 reducer 的，验不到「帧怎么到达 reducer」。

     # 连接生命周期的事件也走这里

     `sys.hello.ok`、断线、被踢**必须与帧保持同一个顺序**：hello.ok 要是排到
     它之后的帧后面，状态机就会拿着旧房间去处理新会话的帧。所以泵里送的是
     `IMLoopWork` 而不是裸帧。
     */
    var frameInlet: AsyncStream<IMLoopWork>.Continuation?
    var framePump: Task<Void, Never>?

    /// WebSocket 工厂的注入口。**只给测试用**，所以是 internal 不是 public——
    /// 宿主该换的是 `IMMediaAdapter`，传输层不是产品的接缝。
    /// （连接层自己那份 `IMConnectionOptions.webSocketFactory` 同理。）
    var webSocketFactory: IMWebSocketFactory?

    /**
     初始化（Swift 用，可带媒体适配器）。

     - Parameter media: 媒体适配器。**可以不传**——「只要信令、UI 自己画」的宿主
       不需要它，那时推流与画面挂载会以 `invalid_state` 失败，其余功能一律照常。
       媒体实现在 iOS-only 的 `IMCallEngineWebRTC` 里，Engine 本身不依赖 libwebrtc。

     `IMMediaAdapter` 刻意**不是** `@objc` 协议：它的方法是 `async throws`，
     而且只被媒体 target 实现一次，没有让 ObjC 宿主自己实现的场景。
     所以这个 init 不导出到 ObjC，ObjC 宿主用下面那个。
     */
    /// - Note: `deviceID` 的合规性在 ``login(_:)`` 里校验，**不在这里**——
    ///   这个 init 是 `@objc` 且不抛错，给它加 `throws` 会打断每一个宿主。
    ///   `login` 本来就 `async throws`，宿主已经在处理它抛的错，
    ///   而且校验发生在开 socket 之前，早到足以起作用。规则见 ``IMDeviceID``。
    public init(url: URL, deviceID: String, media: IMMediaAdapter?) {
        self.url = url
        self.deviceID = deviceID
        self.media = media
        super.init()
        // 内部记账：一轮媒体到此为止就把 openMicrophone/openCamera 的 cid 记账清零，
        // 与 IMFrameLoop.apply 里 media?.close() 的判据（leaveCallbacks）同一张表。
        // 这是 Engine 自己订的 block 观察者，跟宿主挂的那些互不干扰、也不需要 remove
        // （生命周期跟 dispatcher 一样长）。
        _ = dispatcher.addObserver { [weak self] event in
            guard let self, [.callEnd, .roomLeft, .roomClosed].contains(event.name) else { return }
            self.stateQueue.sync {
                self.publishedMicCID = nil
                self.publishedCameraCID = nil
            }
        }
    }

    /// 初始化（ObjC 也能用的纯信令形态：登录、振铃、成员、静音通知一个都不少）。
    @objc public convenience init(url: URL, deviceID: String) {
        self.init(url: url, deviceID: deviceID, media: nil)
    }

    // MARK: - 事件的 block 接法

    /// addEventObserver 用闭包接全部事件，返回退订用的 token。
    ///
    /// 与 delegate 是**同一个分发点**的两个出口（见 IMEventDispatcher），不会分叉。
    @discardableResult
    @objc public func addEventObserver(_ handler: @escaping (IMCallEvent) -> Void) -> NSUUID {
        dispatcher.addObserver(handler) as NSUUID
    }

    /// removeEventObserver 退订。
    @objc public func removeEventObserver(_ token: NSUUID) {
        dispatcher.removeObserver(token as UUID)
    }

    // MARK: - 连接

    /**
     login 建立信令连接并完成握手。

     # 重复调用会被拒掉

     **两条 WS 带着同一个 uid + device_id，服务端会按顶号把先来的那条踢下线**
     （`handshake.go` 的 4403，它自己有 `TestSameDeviceLoginKicksOldConnection` 盯着）。
     旧实现直接覆盖 `connection`，前一条既不关也不撒手，于是宿主收到一个
     **假的 `onKickedOut(.takenOver)`**——「账号在别处登录」，可根本没有别处，
     就是这台机器自己把自己踢了。所以已经有连接时就地抛 `invalid_state`。

     要换账号或换一枚票，先 `logout()`。（连着的时候换票用 `updateToken`。）

     # 失败会把摊子收干净

     握手失败时把连接关掉、`connection` 置回 nil。不收的话上面那道门会把
     **重试**也一起挡掉，用户从此再也登不上——比原来的 bug 还糟。
     */
    @objc public func login(_ token: String) async throws {
        // destroy() 之后是终态：不允许借同一个实例「复活」，逼宿主换一个新的 Engine
        // （见 IMCallEngine+Lifecycle.swift）。
        try guardNotDestroyed()
        // **在开 socket 之前拦**：不拦的话服务端回 1004，而它那句「device_id 只允许
        // [A-Za-z0-9_-]」到不了宿主手里——宿主看到的只有一个 bad_params，
        // 界面上就是「登录失败」四个字。安卓真机上为此查了一轮（见 IMDeviceID）。
        try IMDeviceID.check(deviceID)
        guard currentConnection == nil else {
            throw IMRTCError(.invalidState, "已经登录了：换账号或换票请先 logout()")
        }
        // 帧泵要先起来——它是下行帧进状态机的唯一入口（见 startFramePump）。
        let inlet = startFramePump()
        let connection = makeConnection(token: token, inlet: inlet)
        stateQueue.sync { self.connection = connection }
        media?.open(mediaEvents())
        do {
            _ = try await connection.connect()
        } catch {
            connection.close()
            media?.close()
            stopFramePump()
            stateQueue.sync {
                if self.connection === connection { self.connection = nil }
            }
            throw error
        }
        stallProbe.start()
    }

    /// logout 关掉连接与媒体，并把状态机归零。
    @objc public func logout() async {
        let old = stateQueue.sync { () -> IMSignalConnection? in
            let previous = connection
            connection = nil
            return previous
        }
        stallProbe.stop()
        old?.close()
        media?.close()
        // openMicrophone/openCamera 的记账也要跟着归零——不归零的话，logout 又 login
        // 回来之后头一次 openMicrophone 会把上一段登录期的 cid 当成还发布着（见 destroy()）。
        stateQueue.sync {
            publishedMicCID = nil
            publishedCameraCID = nil
        }
        stopFramePump()
        await loop.reset()
    }

    /**
     updateToken 换一枚新的接入票。**下一次重连时生效，不打断当前连接。**

     # 为什么是宿主推给我们，而不是我们去要

     协议 §1.5 说 `4401` 的处置是「换新 token 后重连」。**换票是宿主的事**——
     票从宿主的账号体系来，Engine 不认识那套东西，也不该替它决定什么时候去要票。
     所以这里是 push 不是 pull：**没有「token provider 回调」那种设计**。

     # 宿主该怎么用

     在 `didDisconnect` 里看到 `code == 4401` 就去取一枚新票、调这个方法。
     重连是已经排好的（第一档 1 秒起），所以只要赶在下一次尝试之前调到就行；
     连续 3 次鉴权失败之后 Engine 会抛 `callEngine(_:wasKickedOutFor:)`（`.authExpired`）收手，
     那时只能重新 `login`。

     连上着的时候调它也是安全的（比如票快过期了提前换）——当前连接不受影响。
     */
    @objc public func updateToken(_ token: String, expiresAtMS: Int64) {
        currentConnection?.updateToken(token, expiresAtMS: expiresAtMS)
    }

    /// 不带到期时刻的旧形态：定时器留到下一次 `sys.hello.ok` 再武装。
    @objc public func updateToken(_ token: String) {
        currentConnection?.updateToken(token, expiresAtMS: 0)
    }

    /// state 是状态机的当前快照，供 UI 渲染。
    public var state: IMEngineContext {
        get async { await loop.ctx }
    }

    // MARK: - 通话

    /// uid 是当前登录的用户。未登录时是空串。
    @objc public var uid: String { stateQueue.sync { myUID } }

    /**
     call 发起通话。`calleeIDs` 上限 8 个（自己 + 8 = 9 人，拍板 §11-1）。

     **呼叫名单里不能有自己**——服务端会以 `1004 bad_params` 拒掉
     （"callee_ids 不能含主叫自己"）。这里在发出去之前就拦下来：那条链路上的
     失败很难看懂，界面已经乐观地进了「正在呼叫…」，而错误只是一条没头没尾的 1004。
     就地拒掉能直接说清是哪个 uid 的问题。
     （实测撞过：Demo 的群呼默认名单里正好有登录的那个人。）
     */
    @objc public func call(_ calleeIDs: [String], mediaType: String,
                           isGroup: Bool = false) async {
        let me = uid
        if !me.isEmpty, calleeIDs.contains(me) {
            dispatcher.emit(IMEmittedEvent("onError", [
                "code": .int(Int64(IMErrorCode.badParams.rawValue)),
                "name": .string(IMErrorCode.badParams.name),
            ]))
            /*
             **本地拒掉也要给界面一个出口。**

             调用方（Kit / 宿主）在调 `call()` 之前就已经切到「正在呼叫…」了——
             这是对的，不然按下去几百毫秒没反应。但只抛一个 error，
             界面不知道该退回哪儿：卡在「正在呼叫…」，点挂断只会收到 2005
             （状态机是 idle，没有 call 可挂），除了杀进程没有别的出路。

             `onCallEnd` 是所有结束分支的唯一出口（设计 §7.5），
             这一条与「服务端拒了 invite」（call_failed）走同一个出口。
            */
            dispatcher.emit(IMEmittedEvent("onCallEnd", [
                "call_id": .string(""),
                "reason": .string(IMCallEndReason.error.wireValue),
                "duration_sec": .int(0),
                "ended_by": .string(""),
            ]))
            IMRTCLog.warn("呼叫名单里含自己，已就地拒掉", ["uid": me])
            return
        }
        await loop.dispatch(.act(op: "call", args: [
            "callee_ids": .array(calleeIDs.map { .string($0) }),
            "media_type": .string(mediaType),
            "is_group": .bool(isGroup),
        ]))
    }

    /// accept 接听。
    @objc public func accept() async {
        await loop.dispatch(.act(op: "accept"))
    }

    /// reject 拒接。
    @objc public func reject() async {
        await loop.dispatch(.act(op: "reject"))
    }

    /// cancel 取消呼叫（**接通前**用这个）。
    @objc public func cancel() async {
        await loop.dispatch(.act(op: "cancel"))
    }

    /// hangup 挂断（**接通后**用这个）。
    ///
    /// **会议房里没有 call**，那里的结束动作是 `leaveRoom()`——
    /// 在会议里调这个会被状态机本地拒成 2005，界面上就是「点了没反应」。
    @objc public func hangup() async {
        await loop.dispatch(.act(op: "hangup"))
    }

    /**
     inviteMore 往进行中的群通话里再拉人（协议 §4.1 `call.invite_more`，四端同名）。

     **通话里的任何人都能发**（2026-09-15 起，原先仅主叫）；还在响铃 / 已离场的人发会被服务端拒成
     `1407 not_call_owner`（交互稿 §05）。房间满了回 `1202 room_full`；离场的发起人也能被重新邀请。
     名单里含自己就地拒掉，理由与 `call` 一样。
     */
    @objc public func inviteMore(_ calleeIDs: [String]) async {
        let me = uid
        if !me.isEmpty, calleeIDs.contains(me) {
            dispatcher.emit(IMEmittedEvent("onError", [
                "code": .int(Int64(IMErrorCode.badParams.rawValue)),
                "name": .string(IMErrorCode.badParams.name),
            ]))
            IMRTCLog.warn("加人名单里含自己，已就地拒掉", ["uid": me])
            return
        }
        await loop.dispatch(.act(op: "invite_more", args: [
            "callee_ids": .array(calleeIDs.map { .string($0) }),
        ]))
    }

    // MARK: - 房间（会议）

    /// joinRoom 直接进一个会议房（不走振铃）。
    @objc public func joinRoom(_ roomID: String, roomToken: String,
                               autoSubscribe: Bool = true) async {
        await loop.dispatch(.act(op: "join", args: [
            "room_id": .string(roomID),
            "room_token": .string(roomToken),
            "auto_subscribe": .bool(autoSubscribe),
        ]))
    }

    /// leaveRoom 离房。**会议的结束动作**。
    @objc public func leaveRoom() async {
        await loop.dispatch(.act(op: "leave"))
    }

    func requireMedia() throws -> IMMediaAdapter {
        try guardNotDestroyed()
        guard let media else {
            throw IMRTCError(.invalidState,
                             "没有媒体适配器：这台 Engine 只做信令，推流/画面需要传入 IMMediaAdapter")
        }
        return media
    }

    /// guardNotDestroyed 是 `login` / `requireMedia`（覆盖 publishMicrophone / publishCamera /
    /// startLocalPreview / probeMicrophone / openMicrophone / openCamera）共用的门。
    /// **internal 而不是 private**：`IMCallEngine+Lifecycle.swift` 也要用。
    func guardNotDestroyed() throws {
        guard !(stateQueue.sync { isDestroyed }) else {
            throw IMRTCError(.invalidState, "Engine 已 destroy()：不能再使用，需要重新创建实例")
        }
    }

    // makeConnection 拆到了 IMCallEngine+Connection.swift（体量红线，CONVENTIONS §2）。
}
