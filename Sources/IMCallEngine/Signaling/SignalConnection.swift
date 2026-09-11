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

/// 握手成功后的服务端信息。
public struct IMHelloOK: Sendable {
    public let uid: String
    public let deviceID: String
    public let sessionID: String
    public let resumed: Bool
    public let pingIntervalSec: Int
    /// 本次握手用的那张票的到期时刻（Unix 毫秒）。**0 = 未知**。
    public let tokenExpiresAtMS: Int64
    public let maxFrameBytes: Int
    public let maxCallees: Int
    public let maxRoomParticipants: Int
    public let ringTimeoutSecDefault: Int
}

/// 连接状态。
public enum IMConnectionState: String, Sendable {
    case idle, connecting, connected, reconnecting, closed
}

/// 连接层对外的回调。**全部在信令队列上调用**。
public struct IMConnectionEvents {
    /**
     握手完成——**每一次**，包括自动重连那些。

     门面必须接住它，并把 `sys.hello.ok` 喂给状态机。**不能只在 `login()` 里喂一遍**：
     重连是连接层自己发起的，那次握手的结果只从这里出来。漏掉的后果不是「少一个事件」，
     而是重连之后状态机根本不知道自己重连了——`resumed == false` 时房间与通话不归零
     （服务端那边早就没了，之后每一帧都发向一个不存在的房间）、`resumed == true` 时
     攒下的意图不重放，宿主也永远收不到第二次 `onConnected`。

     （Web 端就是这么漏的，症状是服务端重启后换票重连其实成功了，界面却一直停在
     「重连中」。见 im-rtc-web 的 `connectionFactory.ts`。）
     */
    public var onConnected: ((IMHelloOK) -> Void)?
    /// 收到服务端主动推送的事件（req_id 为空的帧）。
    public var onEvent: ((String, [String: IMJSON]) -> Void)?
    /// 连接断开。willReconnect=false 时不会再自动回来。
    public var onDisconnected: ((Int, Bool) -> Void)?
    /// 被踢下线，**不会自动重连**。
    ///
    /// `reason` 决定宿主该做什么，两者处置相反——合并成一个「被踢」的话，
    /// 宿主只能都当登录失效处理，把本可静默恢复的场景也变成「请重新登录」。
    public var onKickedOut: ((IMKickedOutReason) -> Void)?
    /**
     断得太久了，**服务端那一侧的会话已经不可能再恢复**（§1.4 的恢复窗口过了）。

     与「重连上了但 `resumed == false`」是同一件事，只是**不必等重连成功**——
     网络一直不回来的话那一刻永远不会到。少了它，界面就永远停在「正在重连」、
     连挂断都点不动（挂断只产出一帧发不出去的 `call.hangup`，本地状态一动不动，
     这是 §4.2 铁律 1 的直接后果）。真机 2026-09-08 的 iOS carol 就是这一幕。
     */
    public var onSessionUnrecoverable: (() -> Void)?
    /// 票快到期了，宿主该去取新票并 `updateToken`。见 `TokenExpiryTimer`。
    public var onTokenWillExpire: ((Int64) -> Void)?
    /// 内部错误。
    public var onError: ((IMRTCError) -> Void)?

    public init() {}
}

/// 构造参数。带 Factory / random 的都是为了测试可注入。
public struct IMConnectionOptions {
    public var url: URL
    public var token: String
    public var deviceID: String
    public var sdk: String = "ios/\(IMCallEngineVersion)"
    /// 请求超时。协议建议 10 秒（§2.2）。
    public var requestTimeoutMS: Int = 10_000
    public var webSocketFactory: IMWebSocketFactory = imURLSessionWebSocketFactory
    public var random: () -> Double = { Double.random(in: 0..<1) }
    /**
     覆盖「断多久算服务端已经放弃这条会话」的时长（毫秒）。**只为测试可注入。**

     真值是 `3×ping + 30s + 余量`（见 `IMSignalConnection.giveUpDelayMS`），
     默认 80 秒——一条用例不可能真等 80 秒，而这条路**全是时序**，
     不测就等于没写（CONVENTIONS §9 点名的那一类）。
     */
    public var resumeGiveUpDelayMSForTesting: Int?

    public init(url: URL, token: String, deviceID: String) {
        self.url = url
        self.token = token
        self.deviceID = deviceID
    }
}

public final class IMSignalConnection {
    private let queue = DispatchQueue(label: "com.imrtc.engine.signaling")
    /// maxAuthFailures 是连续几次 4401 之后彻底放弃（协议 §1.5 关闭码表）。三端同一个数。
    static let maxAuthFailures = 3
    /// 协议 §1.4 的恢复窗口：30 秒。**四端同一个值**，服务端的 `ResumeWindow` 也是它。
    static let resumeWindowSec = 30
    /// 服务端判一条连接死掉要连续几个心跳周期收不到东西（§1.3）。
    static let serverDeathPings = 3
    /// 余量：跨过服务端窗口到期那一刻再收场，别跟它抢同一秒。
    static let giveUpGraceSec = 5

    private var options: IMConnectionOptions
    private var events: IMConnectionEvents

    private var socket: IMWebSocket?
    private var state: IMConnectionState = .idle
    private var sessionID = ""
    private var seq = 0
    private var reconnectAttempt = 0
    /// 还没有结果的那个 `connect()`。见 `takeConnectContinuation()`。
    private var connectContinuation: CheckedContinuation<IMHelloOK, Error>?
    private var reconnectTimer: DispatchSourceTimer?
    /// 服务端最近一次告知的心跳周期。`giveUpDelayMS` 要用它推算服务端何时判死。
    private var pingIntervalSec = 15
    /// 「服务端已经彻底放弃这条会话」的定时器。见 `giveUpDelayMS`。
    private var unrecoverableTimer: DispatchSourceTimer?
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

        let socket = options.webSocketFactory(options.url)
        self.socket = socket
        socket.resume(handlers: IMWebSocketHandlers(
            onOpen: { [weak self] in
                guard let self else { return }
                self.queue.async { self.handshake() }
            },
            onMessage: { [weak self] text in
                guard let self else { return }
                self.queue.async { self.handleMessage(text) }
            },
            onClose: { [weak self] code, reason in
                guard let self else { return }
                self.queue.async { self.handleClose(code: code, reason: reason) }
            }))
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
            case let .success(reply):
                guard reply.envelope.type == IMEnvelope.okType(IMFrameType.hello) else {
                    self.takeConnectContinuation()?.resume(throwing:
                        IMRTCError(.notAuthenticated, "握手应答是 \(reply.envelope.type)"))
                    return
                }
                let ok = self.parseHelloOK(reply.data)
                self.sessionID = ok.sessionID
                self.state = .connected
                self.reconnectAttempt = 0
                self.authFailures = 0
                self.pingIntervalSec = ok.pingIntervalSec
                // 连上了就别再倒计时了——不管 resumed 是真是假，服务端都已经给出裁决。
                self.unrecoverableTimer?.cancel()
                self.unrecoverableTimer = nil
                self.heartbeat.start(intervalSec: ok.pingIntervalSec)
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

    private func parseHelloOK(_ data: [String: IMJSON]) -> IMHelloOK {
        let limits = data["limits"]?.objectValue ?? [:]
        return IMHelloOK(
            uid: Wire.string(data, "uid"),
            deviceID: Wire.string(data, "device_id"),
            sessionID: Wire.string(data, "session_id"),
            resumed: Wire.bool(data, "resumed"),
            pingIntervalSec: Int(Wire.int(data, "ping_interval_sec")),
            tokenExpiresAtMS: Wire.int(data, "token_expires_at_ms"),
            maxFrameBytes: Int(Wire.int(limits, "max_frame_bytes")),
            maxCallees: Int(Wire.int(limits, "max_callees")),
            maxRoomParticipants: Int(Wire.int(limits, "max_room_participants")),
            ringTimeoutSecDefault: Int(Wire.int(limits, "ring_timeout_sec_default")))
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
        if envelope.type == IMFrameType.error {
            let code = IMErrorCode(rawValue: Int(Wire.int(envelope.data, "code"))) ?? .internalError
            if code == .kickedOut { events.onKickedOut?(.takenOver) }
            events.onError?(IMRTCError(code, Wire.string(envelope.data, "msg")))
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

    /*
     断开多久之后可以断定「服务端那一侧的会话没了」。

     # 为什么不是恢复窗口那 30 秒

     服务端的 30 秒**不是从我们断开的那一刻算起的**，是从**它自己察觉**的那一刻算起。
     而它靠读超时察觉：连续 3 个心跳周期收不到任何东西才判死（§1.3）。
     我们断开时距离上一帧最多一个心跳周期，所以最晚的到期时刻是
     `断开 + 3×ping + 30s`——按默认 15 秒心跳就是 45 + 30 = 75 秒，再加一点余量。

     # 为什么必须取上界

     取短了就会撒谎：真机 2026-09-08 那通，断开 14 秒后重连**成功恢复**，通话好端端地继续。
     在那之前宣布「通话已结束」是把一通还能救回来的电话杀掉，而且服务端还认为我们在房里，
     房间会挂着一个幽灵成员。**宁可让用户多看几十秒「正在重连」，也不能提前下结论。**
     */
    var giveUpDelayMS: Int {
        if let override = options.resumeGiveUpDelayMSForTesting { return override }
        return (Self.serverDeathPings * pingIntervalSec + Self.resumeWindowSec + Self.giveUpGraceSec) * 1000
    }

    /**
     起「服务端已经彻底放弃」的倒计时。

     **只在第一次断开时起**：每一次重连失败都会走到这里，每次都重排的话截止时刻
     就一直往后挪、永远不会到——而那正是它要治的病。起点是第一次断开的那一刻，
     与服务端算的是同一笔账。
     */
    private func armUnrecoverableTimer() {
        guard unrecoverableTimer == nil else { return }
        let delay = giveUpDelayMS
        IMRTCLog.info("恢复窗口倒计时已起", ["delay_ms": String(delay)])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(delay))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.unrecoverableTimer = nil
            // 服务端已经丢掉这个会话，再拿它去要 resume 只会白跑一趟。
            self.sessionID = ""
            IMRTCLog.warn("断开已超过恢复窗口，会话不可恢复")
            self.events.onSessionUnrecoverable?()
        }
        unrecoverableTimer = timer
        timer.resume()
    }

    private func scheduleReconnect() {
        let delay = IMBackoff.delayMS(attempt: reconnectAttempt, random: options.random)
        reconnectAttempt += 1
        IMRTCLog.info("计划重连", ["attempt": String(reconnectAttempt), "delay_ms": String(delay)])

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(delay))
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .reconnecting else { return }
            Task { [weak self] in
                guard let self else { return }
                // 重连失败会走 onClose，再排下一次——**不在这里递归重试**，
                // 否则失败得快时会把退避表整个跳过去。
                _ = try? await self.connect()
            }
        }
        reconnectTimer?.cancel()
        reconnectTimer = timer
        timer.resume()
    }

    private func sendPing() {
        guard let socket = self.socket, socket.isOpen else { return }
        seq += 1
        guard let text = encode(IMFrameType.ping, reqID: "i-\(seq)", data: [:]) else { return }
        socket.send(text)
    }
}
