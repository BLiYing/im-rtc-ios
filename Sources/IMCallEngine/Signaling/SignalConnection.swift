import Foundation

/*
 信令连接：握手、心跳、请求应答配对、退避重连。

 # 为什么按 req_id 配对而不是按帧类型

 pub 侧的 `room.offer` 是由 **`room.answer`** 应答的（§3.3 固定 offerer），
 只看类型对不上号。按 req_id 配对还顺带解决了「多个同类请求在途」的问题。

 # 线程

 所有状态都只在 `queue` 这条串行队列上读写（CONVENTIONS §5）。
 回调也在这条队列上抛——**切主线程是门面的事**，在这里切会让每个回调
 都多一次跳转，且顺序不再可控。
 */

public final class IMSignalConnection {
    let queue = DispatchQueue(label: "com.imrtc.engine.signaling")
    /// maxAuthFailures 是连续几次 4401 之后彻底放弃（协议 §1.5 关闭码表）。三端同一个数。
    static let maxAuthFailures = 3

    var options: IMConnectionOptions
    var events: IMConnectionEvents

    var socket: IMWebSocket?
    var state: IMConnectionState = .idle
    var sessionID = ""
    private var seq = 0
    var reconnectAttempt = 0
    /// 还没有结果的那个 `connect()`。见 `takeConnectContinuation()`。
    private var connectContinuation: CheckedContinuation<IMHelloOK, Error>?
    /// 正等着的那次重连。**到点就置 nil**：「在等」与「正在连」要分得开（见 `SignalConnection+Nudge.swift`）。
    var reconnectTimer: DispatchSourceTimer?
    /// 回前台 / 网络变化那一刻正在连、或探测判死要断：这一次失败**不走退避**，立刻再连。
    var networkChangePending = false
    /// 上一次因回前台 / 网络变化而立刻重连的时刻（开机以来纳秒），防重连风暴用。
    var lastNudgeReconnectNS: UInt64 = 0
    /// 回前台 / 网络变化时，连着的那条先探死活。
    private(set) lazy var networkProbe = NetworkProbe(queue: queue)
    /// 服务端最近一次告知的心跳周期。`giveUpDelayMS` 要用它推算服务端何时判死。
    var pingIntervalSec = 15
    /// 「服务端已经彻底放弃这条会话」的定时器。见 `giveUpDelayMS`。
    var unrecoverableTimer: DispatchSourceTimer?
    /// 连续鉴权失败次数。握手一成功、或宿主换了票，就清零——只有**连续**失败才说明票是死的。
    private var authFailures = 0
    /// 票到期提醒。**排程走同一条信令队列**——所有状态变更都在这条线上，不引入第二个并发域。
    private lazy var tokenExpiry = TokenExpiryTimer(
        schedule: { [weak self] delayMS, fire in
            guard let self else { return {} }
            let work = DispatchWorkItem(block: fire)
            self.queue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMS)), execute: work)
            return { work.cancel() }
        },
        onWillExpire: { [weak self] expiresAtMS in
            self?.events.onTokenWillExpire?(expiresAtMS)
        })

    private var pending: PendingRequests!
    private var heartbeat: Heartbeat!

    public init(options: IMConnectionOptions, events: IMConnectionEvents = IMConnectionEvents()) {
        self.options = options
        self.events = events
        self.pending = PendingRequests(queue: queue, timeoutMS: options.requestTimeoutMS)
        self.heartbeat = Heartbeat(
            queue: queue,
            sendPing: { [weak self] in self?.sendPing() },
            onDead: { [weak self] in
                self?.socket?.close(code: IMCloseCode.goingAway, reason: "heartbeat timeout")
            })
    }

    /// currentState 返回连接状态。
    public var currentState: IMConnectionState {
        queue.sync { state }
    }

    /// 当前在用的接入票（含 `updateToken` 换过的）。给同一个身份下的 REST 调用用，不进公开 API。
    var currentToken: String {
        queue.sync { options.token }
    }

    /// currentSessionID 返回会话 id；重连时会带上它请求恢复。
    public var currentSessionID: String {
        queue.sync { sessionID }
    }

    /// updateToken 换一枚新的接入票（旧票过期时用）。**下次连接才生效**。
    ///
    /// 协议里 4401 的含义就是「换个 token 再来」——换票是宿主的事，
    /// Engine 不该自己去要（它不知道宿主的账号体系）。
    ///
    /// **顺带把鉴权失败计数清零**：换票就是「这次不一样了」的唯一信号，
    /// 不清的话已经用光重试次数的连接换了新票也再没有机会试。
    public func updateToken(_ token: String, expiresAtMS: Int64 = 0) {
        queue.async {
            self.options.token = token
            self.authFailures = 0
            // 宿主刚从自家后台拿到票，必然知道它的 expires_in。传了就按新票重新武装；
            // 不传就让旧定时器继续跑到下一次握手——那时 sys.hello.ok 会给出权威值。
            if expiresAtMS > 0 { self.tokenExpiry.arm(expiresAtMS: expiresAtMS) }
        }
    }

    /**
     connect 建立连接并完成握手。

     # 结果必须恰好送达一次

     `connect()` 的 continuation 曾经只交给 `onOpen` 那条路：**连不上的时候
     （服务端没起来、DNS/TLS 失败、飞行模式）socket 根本不会 open，只会 close**，
     于是它悬在那里没人 resume，`login()` 永远不返回也不抛错——宿主界面停在
     「连接中…」，连收摊的 `catch` 都等不到。Swift 运行时对此有明确诊断：
     `SWIFT TASK CONTINUATION MISUSE: connect() leaked its continuation`。

     现在它存进 `connectContinuation`，由 `takeConnectContinuation()` 取走，
     取出即置 nil——**握手成功、握手被拒、连接关闭、被新的尝试取代，四条路都会经过它**，
     谁先到谁负责，天然保证恰好一次。
     */
    public func connect() async throws -> IMHelloOK {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.startConnect(continuation) }
        }
    }

    /// takeConnectContinuation 取走还没有结果的那个 connect，**取出即置 nil**。
    ///
    /// 只在 `queue` 上调用，所以不用锁。返回 nil 表示已经有人给过结果了。
    private func takeConnectContinuation() -> CheckedContinuation<IMHelloOK, Error>? {
        defer { connectContinuation = nil }
        return connectContinuation
    }

    /// close 主动关闭，**不会**触发重连。
    public func close() {
        queue.async {
            self.state = .closed
            self.heartbeat.stop()
            self.networkProbe.stop()
            self.networkChangePending = false
            self.tokenExpiry.disarm()
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            /*
             **只有 logout 撤这条倒计时。**

             其余「不再重连」的路（鉴权连续失败、握手参数被拒）都让它继续走完——
             那些情形下服务端那一侧的会话同样会过期，通话同样该收场；
             撤掉的话界面又会停在「正在重连」上出不来。
             logout 是宿主主动拆掉一切，那之后不该再有任何回调。
            */
            self.unrecoverableTimer?.cancel()
            self.unrecoverableTimer = nil
            self.pending.rejectAll(IMRTCError(.invalidState, "连接已关闭"))
            // 正连着一半就 logout：同样不能把 connect() 的调用方丢在那儿。
            self.takeConnectContinuation()?.resume(throwing:
                IMRTCError(.invalidState, "连接已关闭"))
            self.socket?.close(code: IMCloseCode.normal, reason: "client logout")
            self.socket = nil
        }
    }

    /// request 发一个请求并等它的应答。
    public func request(_ type: String, data: [String: IMJSON]) async throws -> IMRequestResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.state == .connected else {
                    continuation.resume(throwing:
                        IMRTCError(.invalidState, "连接不可用（当前 \(self.state.rawValue)）"))
                    return
                }
                self.dispatchRequest(type, data: data) { continuation.resume(with: $0) }
            }
        }
    }

    /// sendFrame 发一帧但不等应答（对服务端事件的回应，如 sub 的 answer）。
    public func sendFrame(_ type: String, reqID: String, data: [String: IMJSON]) {
        queue.async {
            guard let socket = self.socket, socket.isOpen else { return }
            guard let text = self.encode(type, reqID: reqID, data: data) else { return }
            socket.send(text)
        }
    }

    /// fire 发一个请求但**不等应答**：应答照常按 req_id 配对后丢掉，不会漏进事件流。
    ///
    /// 只给 `IMCallEngine.forceEnd()` 用。它要能从任何线程同步调用、立刻上线路——
    /// 走 `request` 得先在 Swift 并发里排上号，2026-09-13 那次挂断没发出去，卡的正是那一段。
    public func fire(_ type: String, data: [String: IMJSON]) {
        queue.async {
            guard self.state == .connected else {
                IMRTCLog.warn("帧没发出去：连接不可用", ["type": type, "state": self.state.rawValue])
                return
            }
            self.dispatchRequest(type, data: data) { result in
                guard case let .failure(error) = result else { return }
                IMRTCLog.info("不等应答的请求失败了", ["type": type, "code": String(error.code.rawValue)])
            }
        }
    }

    // MARK: - 内部（全部在 queue 上）

    private func startConnect(_ continuation: CheckedContinuation<IMHelloOK, Error>) {
        if state == .connected {
            continuation.resume(throwing: IMRTCError(.invalidState, "已经连上了"))
            return
        }
        // 上一次尝试还没有结果就又开一次（重连定时器与 login 撞在一起）：
        // 先把它结束掉。**绝不让任何一个 continuation 悬着。**
        takeConnectContinuation()?.resume(throwing:
            IMRTCError(.invalidState, "有新的连接尝试取代了它"))
        connectContinuation = continuation
        state = sessionID.isEmpty ? .connecting : .reconnecting

        retireStaleSocket()
        let socket = options.webSocketFactory(options.url)
        self.socket = socket
        // **只认当前这条 socket 的事件**：旧的迟到了就丢掉，否则会把新连接当成断了（见 retireStaleSocket）。
        let id = ObjectIdentifier(socket)
        socket.resume(handlers: IMWebSocketHandlers(
            onOpen: { [weak self] in
                guard let self else { return }
                self.queue.async { if self.isCurrent(id) { self.handshake() } }
            },
            onMessage: { [weak self] text in
                guard let self else { return }
                self.queue.async { if self.isCurrent(id) { self.handleMessage(text) } }
            },
            onClose: { [weak self] code, reason in
                guard let self else { return }
                self.queue.async { if self.isCurrent(id) { self.handleClose(code: code, reason: reason) } }
            }))
    }

    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        socket.map(ObjectIdentifier.init) == id
    }

    /**
     retireStaleSocket 在换新 socket 之前，把上一条还挂着的关掉。

     握手还在飞时宿主又调了 `login`（或别的路又开了一次连接），旧 socket 就还开着。
     不关它就一直泄漏；它迟到的关闭事件还会把新连接当成断了——Web 端 2026-09-19 真机踩过：
     新 socket 上在飞的 hello 被拒、又排一轮重连，如此循环。先把 `socket` 换成 nil
     再关，它的关闭回调就过不了 `isCurrent`。
     */
    private func retireStaleSocket() {
        guard let stale = socket else { return }
        socket = nil
        stale.close(code: IMCloseCode.goingAway, reason: "superseded")
    }

    /// handshake 发 `sys.hello`。
    ///
    /// **它必须在 connecting 状态下发出去**，所以走的是不检查状态的 dispatchRequest。
    /// Web 端在这里踩过一次：让握手走公开的 request()，被状态检查挡住，
    /// 所有时序测试都挂在「一帧都没发出去」。
    private func handshake() {
        var hello = FieldCodec.defaults(SysFrames.hello)
        hello["token"] = .string(options.token)
        hello["device_id"] = .string(options.deviceID)
        hello["session_id"] = .string(sessionID)
        hello["sdk"] = .string(options.sdk)

        IMRTCLog.debug("发送 sys.hello", [
            "device_id": options.deviceID,
            "session_id": sessionID,
            // 凭据只打前 6 位 + 长度（CONVENTIONS §6）。
            "token": IMRTCLog.redact(options.token),
        ])

        dispatchRequest(IMFrameType.hello, data: hello) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                self.abortIfHandshakeRejected(error)
                self.takeConnectContinuation()?.resume(throwing: error)
                /*
                 **本地等应答超时要自己关连接。** 服务端拒了握手会在 100ms 内关（§1.2），
                 关闭码交给 handleClose 按规则决定重不重连（4401 计数靠它，所以被拒时不抢着关）。
                 但超时说明下行半死（服务端收到了 hello、回的帧没到），服务端那头没有理由断——
                 重连又只挂在 onClose 上，不关就要干等服务端 45 秒读超时，恢复窗口白白耗掉。
                 Android 握手失败一律 closeAndReconnect，这里只补超时这一种。
                */
                if error.code == .signalingTimeout {
                    self.socket?.close(code: IMCloseCode.goingAway, reason: "hello timeout")
                }
            case let .success(reply):
                guard reply.envelope.type == IMEnvelope.okType(IMFrameType.hello) else {
                    self.takeConnectContinuation()?.resume(throwing:
                        IMRTCError(.notAuthenticated, "握手应答是 \(reply.envelope.type)"))
                    return
                }
                let ok = IMHelloOK(wire: reply.data)
                self.sessionID = ok.sessionID
                self.state = .connected
                self.reconnectAttempt = 0
                self.networkChangePending = false
                self.authFailures = 0
                self.pingIntervalSec = Heartbeat.clampedIntervalSec(ok.pingIntervalSec)
                // 连上了就别再倒计时了——不管 resumed 是真是假，服务端都已经给出裁决。
                self.unrecoverableTimer?.cancel()
                self.unrecoverableTimer = nil
                self.heartbeat.start(intervalSec: self.pingIntervalSec)
                self.tokenExpiry.arm(expiresAtMS: ok.tokenExpiresAtMS)
                IMRTCLog.info("信令已连接", ["uid": ok.uid, "resumed": String(ok.resumed)])
                // 先抛事件再 resume：`connect()` 返回时，门面那边的状态机应该已经吃过
                // hello.ok 了——首次登录的调用方 await 到的就该是最终状态。
                self.events.onConnected?(ok)
                self.takeConnectContinuation()?.resume(returning: ok)
            }
        }
    }

    /// 握手被拒且重试不可能变好时，一次就放弃，按 ``handshakeGiveUpReason(_:)`` 的分类抛给宿主。
    ///
    /// `state = .closed` 就是那道闩：重连定时器的处理块只在 `.reconnecting` 时才动手，
    /// 随后到来的 `handleClose` 也会因为它而把 `willReconnect` 判成 false。
    private func abortIfHandshakeRejected(_ error: IMRTCError) {
        guard let reason = handshakeGiveUpReason(error) else { return }
        IMRTCLog.error("握手被拒，不再重连", [
            "code": String(error.code.rawValue),
            "name": error.code.name,
            "reason": String(describing: reason),
        ])
        reconnectTimer?.cancel()
        reconnectTimer = nil
        tokenExpiry.disarm()
        state = .closed
        events.onKickedOut?(reason)
    }

    private func dispatchRequest(_ type: String, data: [String: IMJSON],
                                 complete: @escaping (Result<IMRequestResult, IMRTCError>) -> Void) {
        guard let socket = self.socket else {
            complete(.failure(IMRTCError(.invalidState, "还没有连接")))
            return
        }
        seq += 1
        let reqID = "i-\(seq)"
        guard let text = encode(type, reqID: reqID, data: data) else {
            complete(.failure(IMRTCError(.badParams, "\(type) 编码失败")))
            return
        }
        pending.track(reqID: reqID, type: type, complete: complete)
        socket.send(text)
    }

    private func encode(_ type: String, reqID: String, data: [String: IMJSON]) -> String? {
        let envelope = IMEnvelope(type: type, reqID: reqID,
                                  timestampMS: Int64(Date().timeIntervalSince1970 * 1000),
                                  data: data)
        do {
            return try envelope.encode()
        } catch {
            events.onError?(error as? IMRTCError ?? IMRTCError(.internalError, "\(error)"))
            return nil
        }
    }

    private func handleMessage(_ text: String) {
        // 收到**任何**帧都算对端活着，不只是 pong（§1.3）。
        heartbeat.noteFrameReceived()
        networkProbe.noteFrameReceived()

        let envelope: IMEnvelope
        do {
            envelope = try IMEnvelope.decode(text)
        } catch {
            // 解不开的帧是对端的实现 bug。抛给宿主并断开——继续读只会读到更多垃圾。
            events.onError?(error as? IMRTCError ?? IMRTCError(.badEnvelope, "\(error)"))
            socket?.close(code: IMCloseCode.badProtocol, reason: "undecodable frame")
            return
        }

        if !envelope.reqID.isEmpty,
           pending.settle(envelope, decode: { self.decodeData($0) }) {
            return
        }
        dispatchEvent(envelope)
    }

    private func dispatchEvent(_ envelope: IMEnvelope) {
        // sys.pong 没有任何消费者：心跳的判活在 handleMessage 里已经做过
        // （收到**任何**帧都算对端活着，不只是 pong），到这里已经没有下文，
        // 不必再走一遍 decode 把它送进 IMFrameLoop 的管线里空转。
        if envelope.type == IMFrameType.pong {
            return
        }
        if envelope.type == IMFrameType.error {
            let decoded = IMSysErrorFrame.decode(envelope.data)
            let code = decoded.known ?? .internalError
            if code == .kickedOut { events.onKickedOut?(.takenOver) }
            events.onError?(IMRTCError(code, decoded.msg))
            return
        }
        guard IMFrameRegistry.fields(for: envelope.type) != nil else {
            // §2.3：客户端收到未知 type **必须静默忽略**——服务端可能比我们新。
            IMRTCLog.debug("忽略未知帧", ["type": envelope.type])
            return
        }
        events.onEvent?(envelope.type, decodeData(envelope))
    }

    /// decodeData 返回**线路形状**（snake_case）的规范化 data。
    ///
    /// 保持 snake_case 是因为**状态机吃的是线路形状**——它跑的一致性向量就是线路形状，
    /// 换成别的命名会让状态机与向量之间多一层翻译，而那层翻译没人测。
    private func decodeData(_ envelope: IMEnvelope) -> [String: IMJSON] {
        (try? envelope.decodedData()) ?? envelope.data
    }

    private func handleClose(code: Int, reason: String) {
        heartbeat.stop()
        networkProbe.stop()
        socket = nil
        // 断线时把所有在途请求一次性失败掉——不做的话它们会一直挂到超时，
        // 用户看到的是「点了没反应」，而真实原因明明早就知道了。
        pending.rejectAll(IMRTCError(.networkUnreachable, "连接已断开"))
        /*
         **握手还没发出去就断了的那一种，`rejectAll` 够不着。**

         socket 没 open 过就没有在途的 `sys.hello`，在途表是空的；而 `connect()`
         的 continuation 那时还挂在 `connectContinuation` 上。这一行就是它的兜底：
         没有它，服务端没起来时 `login()` 永远不返回（真机与单测都验过）。

         握手已经发出去的那一种，上面的 `rejectAll` 会先把 hello 结算成失败、
         那条路已经取走了 continuation，所以这里拿到 nil，不会重复 resume。
        */
        takeConnectContinuation()?.resume(throwing:
            IMRTCError(.networkUnreachable, "连接已断开（关闭码 \(code)）"))

        if code == IMCloseCode.kickedOut { events.onKickedOut?(.takenOver) }

        /*
         4401 要计数。重连**带的是同一枚 token**，所以协议 §1.5 的「换新 token 后重连」
         这条规则只有配上一个上限才成立——否则一枚废票能自己重试到天荒地老。
         Web 端实测过：服务端重启换了签名密钥，一个没关的标签页重试到第 19 次还在敲，
         日志里全是 token_invalid，把真正的问题淹掉了。
         连续 3 次之后抛 onKickedOut，让宿主回登录页重新取票。
         */
        var exhausted = false
        if code == IMCloseCode.unauthorized {
            authFailures += 1
            exhausted = authFailures >= Self.maxAuthFailures
            if exhausted {
                IMRTCLog.info("鉴权连续失败，停止重连", ["failures": String(authFailures)])
                reconnectTimer?.cancel()
                reconnectTimer = nil
                events.onKickedOut?(.authExpired)
            }
        }

        let willReconnect = !exhausted && state != .closed && IMCloseCode.shouldReconnect(code)
        events.onDisconnected?(code, willReconnect)
        guard willReconnect else {
            state = .closed
            return
        }
        state = .reconnecting
        armUnrecoverableTimer()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        if networkChangePending {
            reconnectRightAway(rule: "网络变化或回前台时正在连，失败后立即再连")
            return
        }
        let delay = IMBackoff.delayMS(attempt: reconnectAttempt, random: options.random)
        reconnectAttempt += 1
        IMRTCLog.info("计划重连", ["attempt": String(reconnectAttempt), "delay_ms": String(delay)])

        let timer = imAfter(.milliseconds(delay), on: queue) { [weak self] in
            guard let self, self.state == .reconnecting else { return }
            self.reconnectTimer = nil
            Task { [weak self] in
                guard let self else { return }
                // 重连失败会走 onClose，再排下一次——**不在这里递归重试**，
                // 否则失败得快时会把退避表整个跳过去。
                _ = try? await self.connect()
            }
        }
        reconnectTimer?.cancel()
        reconnectTimer = timer
    }

    func sendPing() {
        guard let socket = self.socket, socket.isOpen else { return }
        seq += 1
        guard let text = encode(IMFrameType.ping, reqID: "i-\(seq)", data: [:]) else { return }
        socket.send(text)
    }
}
