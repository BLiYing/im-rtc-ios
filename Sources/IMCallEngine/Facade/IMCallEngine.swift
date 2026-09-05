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

    private let url: URL
    private let deviceID: String
    private let media: IMMediaAdapter?

    private lazy var dispatcher = IMEventDispatcher(engine: self)
    private lazy var sender = IMFrameSender(media: media)
    private lazy var loop = IMFrameLoop(
        sender: sender, dispatcher: dispatcher, media: media,
        connection: { [weak self] in self?.currentConnection })

    /// connection 归 `stateQueue`。重连不会换 `IMSignalConnection` 对象，
    /// 但 login/logout 会——所以它是可变的。
    private var connection: IMSignalConnection?
    private let stateQueue = DispatchQueue(label: "com.imrtc.engine.facade")

    private var currentConnection: IMSignalConnection? {
        stateQueue.sync { connection }
    }

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
    public init(url: URL, deviceID: String, media: IMMediaAdapter?) {
        self.url = url
        self.deviceID = deviceID
        self.media = media
        super.init()
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

    /// login 建立信令连接并完成握手。
    @objc public func login(_ token: String) async throws {
        let connection = makeConnection(token: token)
        stateQueue.sync { self.connection = connection }
        media?.open(mediaEvents())
        _ = try await connection.connect()
    }

    /// logout 关掉连接与媒体，并把状态机归零。
    @objc public func logout() async {
        let old = stateQueue.sync { () -> IMSignalConnection? in
            let previous = connection
            connection = nil
            return previous
        }
        old?.close()
        media?.close()
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
     连续 3 次鉴权失败之后 Engine 会抛 `callEngineDidGetKickedOut` 收手，
     那时只能重新 `login`。

     连上着的时候调它也是安全的（比如票快过期了提前换）——当前连接不受影响。
     */
    @objc public func updateToken(_ token: String) {
        currentConnection?.updateToken(token)
    }

    /// state 是状态机的当前快照，供 UI 渲染。
    public var state: IMEngineContext {
        get async { await loop.ctx }
    }

    // MARK: - 通话

    /// call 发起通话。`calleeIDs` 上限 8 个（自己 + 8 = 9 人，拍板 §11-1）。
    @objc public func call(_ calleeIDs: [String], mediaType: String,
                           isGroup: Bool = false) async {
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

    // MARK: - 媒体

    /**
     publishMicrophone 发布麦克风，返回轨道的 cid。

     顺序是**先拿轨道再发 publish**：msid 的第二段就是 cid，服务端靠它认领
     m-line（协议 §3.2），所以不能先想一个 cid。
     */
    @objc public func publishMicrophone() async throws -> String {
        let info = try await requireMedia().acquireMicrophone()
        await publish(info, simulcast: false)
        return info.cid
    }

    /// publishCamera 发布摄像头，返回轨道的 cid。
    @objc public func publishCamera(simulcast: Bool = true) async throws -> String {
        let info = try await requireMedia().acquireCamera(simulcast: simulcast)
        await publish(info, simulcast: simulcast)
        return info.cid
    }

    /**
     setMuted 开关本端某条轨道。

     **这不是 unpublish**：轨道与协商都保留，只是停止发包。
     反复开关摄像头走 unpublish 会触发重协商风暴（协议 §3.2）。
     */
    /// - Note: 第二个参数**必须带标签**：两个都不带的话生成的 ObjC 选择器是
    ///   `setMuted::completionHandler:`，宿主写出来是 `[engine setMuted:cid :YES ...]`
    ///   那种带空标签的怪东西。（Demo 里那段 ObjC 编译检查就是干这个的。）
    @objc public func setMuted(_ cid: String, muted: Bool) async {
        media?.setMuted(cid, muted)
        guard let trackID = await loop.ctx.room.publishTrackIDs[cid] else { return }
        await loop.dispatch(.act(op: "mute", args: [
            "track_id": .string(trackID), "muted": .bool(muted),
        ]))
    }

    /// setSpeakerOn 切换扬声器 / 听筒（设计文档 §7.5 的 `setAudioRoute`）。
    ///
    /// 没有媒体适配器时静默忽略：纯信令形态的 Engine 没有音频可路由。
    @objc public func setSpeakerOn(_ on: Bool) {
        media?.setSpeakerOn(on)
    }

    /// attachView 把某个 uid 的远端画面挂到视图上；传 nil 卸载。
    ///
    /// **这是 UI 拿到画面的唯一途径**（CONVENTIONS §1）：Kit 不许自己碰
    /// PeerConnection，也不该自己拼流。换媒体实现时界面一行不用改。
    @objc public func attachView(_ uid: String, to view: AnyObject?) {
        media?.attachRemoteView(uid, view)
    }

    /// attachLocalView 把本端某条轨道挂到视图上做预览；传 nil 卸载。
    @objc public func attachLocalView(_ cid: String, to view: AnyObject?) {
        media?.attachLocalView(cid, view)
    }

    /**
     setRemoteLayer 报某人画面的**层上界**（协议 §3.5：上界不是命令）。

     九宫格缩略图报 `l`、双击放大报 `h`。**不触发重协商**，也不保证立刻切——
     服务端要等目标层的关键帧，还会再按带宽估计压一次。
     */
    @objc public func setRemoteLayer(_ uid: String, layer: String) async {
        for (trackID, info) in await loop.ctx.room.remoteTracks
        where info.uid == uid && info.kind == "video" {
            await loop.dispatch(.act(op: "update_layer", args: [
                "track_id": .string(trackID), "max_layer": .string(layer),
            ]))
        }
    }

    // MARK: - 内部

    private func publish(_ info: IMLocalTrackInfo, simulcast: Bool) async {
        await loop.dispatch(.act(op: "publish", args: [
            "cid": .string(info.cid),
            "kind": .string(info.kind),
            "source": .string(info.source),
            "simulcast": .bool(simulcast),
        ]))
    }

    private func requireMedia() throws -> IMMediaAdapter {
        guard let media else {
            throw IMRTCError(.invalidState,
                             "没有媒体适配器：这台 Engine 只做信令，推流/画面需要传入 IMMediaAdapter")
        }
        return media
    }

    private func makeConnection(token: String) -> IMSignalConnection {
        var options = IMConnectionOptions(url: url, token: token, deviceID: deviceID)
        options.sdk = "ios/0.0.1"
        if let webSocketFactory { options.webSocketFactory = webSocketFactory }
        var events = IMConnectionEvents()
        /*
         **握手结果一律从这里进状态机**，`login()` 不自己喂一遍。

         只在 login 里喂的话，自动重连那次握手就没人接——状态机不知道自己重连了
         （`resumed == false` 时房间与通话不归零、`resumed == true` 时攒下的意图
         不重放），宿主也收不到第二次 didConnect。Web 端实测的症状是：
         服务端重启后换票重连其实成功了，界面却一直停在「重连中」。
         */
        events.onConnected = { [weak self] hello in
            guard let self else { return }
            Task {
                await self.loop.dispatch(.recv(type: IMEnvelope.okType(IMFrameType.hello), data: [
                    "session_id": .string(hello.sessionID),
                    "resumed": .bool(hello.resumed),
                ]))
            }
        }
        events.onEvent = { [weak self] type, data in
            guard let self else { return }
            Task { await self.loop.handleIncoming(type, data) }
        }
        events.onDisconnected = { [weak self] code, willReconnect in
            guard let self else { return }
            Task { await self.loop.dispatch(.internalEvent(name: "disconnected")) }
            // 关闭码只有连接层知道，所以这一条由它独占上报（见 IMFrameLoop.dispatch）。
            self.dispatcher.emitConnectionEvent(.disconnected, [
                "code": NSNumber(value: code), "will_reconnect": NSNumber(value: willReconnect),
            ])
        }
        events.onKickedOut = { [weak self] in
            guard let self else { return }
            Task { await self.loop.dispatch(.internalEvent(name: "ws_closed_4403")) }
        }
        events.onError = { [weak self] error in
            self?.dispatcher.emit(IMEmittedEvent("onError", [
                "code": .int(Int64(error.code.rawValue)),
                "name": .string(error.code.name),
            ]))
        }
        return IMSignalConnection(options: options, events: events)
    }

    private func mediaEvents() -> IMMediaAdapterEvents {
        var events = IMMediaAdapterEvents()
        events.onLocalCandidate = { [weak self] pc, candidate in
            guard let self else { return }
            Task { await self.loop.sendCandidate(pc, candidate) }
        }
        events.onConnectionStateChange = { [weak self] pc, state in
            guard let self else { return }
            IMRTCLog.debug("PC 状态", ["pc": pc.wireValue, "state": state])
            guard pc == .sub, state == "connected" else { return }
            Task { await self.loop.dispatch(.internalEvent(name: "media_ready")) }
        }
        events.onFirstVideoFrame = { [weak self] trackID in
            guard let self else { return }
            Task {
                let uid = await self.loop.uidOf(trackID)
                self.dispatcher.emit(IMEmittedEvent("onFirstVideoFrame", [
                    "uid": .string(uid), "track_id": .string(trackID),
                ]))
            }
        }
        return events
    }
}
