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

 # 方法的结果回给调用方（2.0.0）

 发请求的方法（`login` / `call` / `joinCall` / `accept` / `reject` / `cancel` / `hangup` /
 `inviteMore` / `joinRoom` / `leaveRoom` / `publish*` / `open*` / `setMuted`）是 `async throws`：
 **这次调用直接发出的那一帧收到应答时返回**，被本地拒绝、被服务端拒绝、超时、没连接、等应答时断线
 **throw 一个 `IMRTCError`**（ObjC 是 completionHandler 的 `NSError`）——这个错误**不再**同时走
 `didFailWithError`。引擎随后自动发的连锁帧（接听之后的进房等）失败找不到调用方，才走 `didFailWithError`。

 通话 / 房间因此收场时 `callDidEnd(.error)` / `didLeaveRoom` 照发，而且**先于** throw：
 **界面收起靠回调，catch 里只做提示**。退出类（`reject` / `cancel` / `hangup` / `leaveRoom`）
 失败时本地照样收场，错误只供日志。规则全文见 server `docs/design/ACTION_RESULT_DESIGN.md`。
 */
@objc public final class IMCallEngine: NSObject {

    /// 回调总表的接收方。**weak**（CONVENTIONS §7）。`destroy()` 之后再设会被拦掉（保持 nil）。
    @objc public weak var delegate: IMCallEngineDelegate? {
        get { dispatcher.delegate }
        set {
            guard newValue == nil || !(stateQueue.sync { isDestroyed }) else {
                IMRTCLog.warn("Engine 已 destroy()：忽略 delegate 设置", [:])
                return
            }
            dispatcher.delegate = newValue
        }
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

    /// emitLocalError 抛一条**本地**错误码（协议 §7.2，永不出现在线路上）。只给找不到调用方的错误用（媒体故障）。
    func emitLocalError(_ code: IMErrorCode) {
        dispatcher.emit(IMEmittedEvent.error(code))
    }

    /// emitUnattributed 把提示类 / 清理类方法里吞下的失败转成 `didFailWithError`（带 `forType`）。
    func emitUnattributed(_ error: Error) {
        let rtc = error as? IMRTCError ?? IMRTCError(.internalError, String(describing: error))
        dispatcher.emit(IMEmittedEvent.error(rtc))
    }

    /**
     act 是「发一个业务动作、等这次调用的结果」的公共外壳：`call` / `accept` / `reject` / `cancel` /
     `hangup` / `inviteMore` / `joinCall` / `joinRoom` / `leaveRoom` / 发布 / 静音共用。
     顺带把 `destroy()` 之后的 2005 收在一处。结算规则见 `IMFrameLoop.request`。
     */
    @discardableResult
    func act(_ op: String, _ args: [String: IMJSON] = [:]) async throws -> [String: IMJSON] {
        try guardNotDestroyed()
        return try await loop.request(.act(op: op, args: args))
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
    /// `destroy()` 之后调用不再登记（返回的 token 照样能拿去 remove，是空操作）。
    @discardableResult
    @objc public func addEventObserver(_ handler: @escaping (IMCallEvent) -> Void) -> NSUUID {
        guard !(stateQueue.sync { isDestroyed }) else {
            IMRTCLog.warn("Engine 已 destroy()：忽略 addEventObserver", [:])
            return NSUUID()
        }
        return dispatcher.addObserver(handler) as NSUUID
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
        guard !(stateQueue.sync { isDestroyed }) else { return }
        currentConnection?.updateToken(token, expiresAtMS: expiresAtMS)
    }

    /// 不带到期时刻的旧形态：定时器留到下一次 `sys.hello.ok` 再武装。
    @objc public func updateToken(_ token: String) {
        updateToken(token, expiresAtMS: 0)
    }

    /// state 是状态机的当前快照，供 UI 渲染。
    public var state: IMEngineContext {
        get async { await loop.ctx }
    }

    // MARK: - 通话

    /// uid 是当前登录的用户。未登录时是空串。
    @objc public var uid: String { stateQueue.sync { myUID } }

    /**
     call 发起通话，**返回服务端分配的 callID**（取自 `call.invite.ok`）。`calleeIDs` 上限 8 个（自己 + 8 = 9 人，拍板 §11-1）。

     **呼叫名单里不能有自己**——服务端会以 `1004 bad_params` 拒掉
     （"callee_ids 不能含主叫自己"）。这里在发出去之前就拦下来：那条链路上的
     失败很难看懂，界面已经乐观地进了「正在呼叫…」，而错误只是一条没头没尾的 1004。
     就地拒掉能直接说清是哪个 uid 的问题。
     （实测撞过：Demo 的群呼默认名单里正好有登录的那个人。）

     被拒（本地 1004 / 服务端拒绝 / 超时）时 throw，**并且先照发一次 `callDidEnd(.error)`**——
     界面在调用之前就切到了「正在呼叫…」，收起它靠那个回调（见 `rejectCallLocally`）。
     */
    @objc public func call(_ calleeIDs: [String], mediaType: String,
                           isGroup: Bool = false) async throws -> String {
        try await call(calleeIDs, mediaType: mediaType, options: IMCallOptions(isGroup: isGroup))
    }

    /// accept 接听。**返回 = 服务端受理了（`call.accept.ok`）**；接通事件随后到。
    @objc public func accept() async throws {
        try await act("accept")
    }

    /// reject 拒接。失败（通话已结束等）时本地照样收场，错误只供日志。
    @objc public func reject() async throws {
        try await act("reject")
    }

    /// cancel 取消呼叫（**接通前**用这个）。失败时本地照样收场，错误只供日志。
    @objc public func cancel() async throws {
        try await act("cancel")
    }

    /// hangup 挂断（**接通后**用这个）。失败时本地照样收场（`callDidEnd` 照发），错误只供日志。
    ///
    /// **会议房里没有 call**，那里的结束动作是 `leaveRoom()`——
    /// 在会议里调这个会被状态机本地拒成 2005（throw 给调用方）。
    @objc public func hangup() async throws {
        try await act("hangup")
    }

    /**
     inviteMore 往进行中的群通话里再拉人（协议 §4.1 `call.invite_more`，四端同名）。

     **通话里的任何人都能发**（2026-09-15 起，原先仅主叫）；还在响铃 / 已离场的人发会被服务端拒成
     `1407 not_call_owner`（交互稿 §05）。房间满了回 `1202 room_full`；宿主拒绝 `1409`；离场的发起人也能被重新邀请。
     这些都 throw 给调用方，通话本身不受影响。名单里含自己就地 throw `1004`，理由与 `call` 一样。
     */
    @objc public func inviteMore(_ calleeIDs: [String]) async throws {
        try guardNotDestroyed()
        let me = uid
        if !me.isEmpty, calleeIDs.contains(me) {
            // 与 call() 不同：这里已经在通话中，不需要（也不该）补一条 onCallEnd，
            // 通话本身没受影响，只是这次加人没发出去。
            IMRTCLog.warn("加人名单里含自己，已就地拒掉", ["uid": me])
            throw IMRTCError(.badParams, "加人名单里含自己", forType: IMFrameType.callInviteMore)
        }
        try await act("invite_more", ["callee_ids": .array(calleeIDs.map { .string($0) })])
    }

    // MARK: - 房间（会议）

    /**
     joinRoom 直接进一个会议房（不走振铃）。**返回 = `room.join.ok` 落进了状态机**。

     `autoSubscribe` 是服务端替你自动订多少（协议 §3.1，2.0.0 起是三档字符串）：

     - `"all"`（默认）音视频全自动订上，通话房与小会议用它；
     - `"audio"` **会议分页画廊用这一档**：音频照旧自动订上（页外的人说话也听得见），
       视频一条都不自动订，由 `setRemoteLayer(_:layer:)` 按当前页订与退
       （`none` = 五秒后退订，见 MEETING_ROOM_DESIGN §4.3）；
     - `"none"` 一条都不自动订，全部由宿主自己订。

     认不出的值按 §2.4 规则 6 兜底成 `"all"`。
     */
    @objc public func joinRoom(_ roomID: String, roomToken: String,
                               autoSubscribe: String = "all") async throws {
        try await act("join", [
            "room_id": .string(roomID),
            "room_token": .string(roomToken),
            "auto_subscribe": .string(autoSubscribe),
        ])
    }

    /// leaveRoom 离房。**会议的结束动作**。失败时本地照样收场（`didLeaveRoom` 照发），错误只供日志。
    @objc public func leaveRoom() async throws {
        try await act("leave")
    }

    func requireMedia() throws -> IMMediaAdapter {
        try guardNotDestroyed()
        guard let media else {
            throw IMRTCError(.invalidState,
                             "没有媒体适配器：这台 Engine 只做信令，推流/画面需要传入 IMMediaAdapter")
        }
        return media
    }

    /// guardNotDestroyed 是发起类与本地设备类方法共用的门（`login` / `act` / `requireMedia` / `setMuted` /
    /// `switchCamera` …），`destroy()` 之后一律 throw 2005。见 `IMCallEngine+Lifecycle.swift`。
    func guardNotDestroyed() throws {
        guard !(stateQueue.sync { isDestroyed }) else {
            throw IMRTCError(.invalidState, "Engine 已 destroy()：不能再使用，需要重新创建实例")
        }
    }

    // makeConnection 拆到了 IMCallEngine+Connection.swift（体量红线，CONVENTIONS §2）。
}
