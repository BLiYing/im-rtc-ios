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
    /// 收到服务端主动推送的事件（req_id 为空的帧）。
    public var onEvent: ((String, [String: IMJSON]) -> Void)?
    /// 连接断开。willReconnect=false 时不会再自动回来。
    public var onDisconnected: ((Int, Bool) -> Void)?
    /// 被踢（同 uid 同 device_id 在别处登录）。
    public var onKickedOut: (() -> Void)?
    /// 内部错误。
    public var onError: ((IMRTCError) -> Void)?

    public init() {}
}

/// 构造参数。带 Factory / random 的都是为了测试可注入。
public struct IMConnectionOptions {
    public var url: URL
    public var token: String
    public var deviceID: String
    public var sdk: String = "ios/0.0.1"
    /// 请求超时。协议建议 10 秒（§2.2）。
    public var requestTimeoutMS: Int = 10_000
    public var webSocketFactory: IMWebSocketFactory = imURLSessionWebSocketFactory
    public var random: () -> Double = { Double.random(in: 0..<1) }

    public init(url: URL, token: String, deviceID: String) {
        self.url = url
        self.token = token
        self.deviceID = deviceID
    }
}

public final class IMSignalConnection {
    private let queue = DispatchQueue(label: "com.imrtc.engine.signaling")
    private var options: IMConnectionOptions
    private var events: IMConnectionEvents

    private var socket: IMWebSocket?
    private var state: IMConnectionState = .idle
    private var sessionID = ""
    private var seq = 0
    private var reconnectAttempt = 0
    private var reconnectTimer: DispatchSourceTimer?

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
    public func updateToken(_ token: String) {
        queue.async { self.options.token = token }
    }

    /// connect 建立连接并完成握手。
    public func connect() async throws -> IMHelloOK {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.startConnect(continuation) }
        }
    }

    /// close 主动关闭，**不会**触发重连。
    public func close() {
        queue.async {
            self.state = .closed
            self.heartbeat.stop()
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            self.pending.rejectAll(IMRTCError(.invalidState, "连接已关闭"))
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
        state = sessionID.isEmpty ? .connecting : .reconnecting

        let socket = options.webSocketFactory(options.url)
        self.socket = socket
        socket.resume(handlers: IMWebSocketHandlers(
            onOpen: { [weak self] in
                guard let self else { return }
                self.queue.async { self.handshake(continuation) }
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
    private func handshake(_ continuation: CheckedContinuation<IMHelloOK, Error>) {
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
                continuation.resume(throwing: error)
            case let .success(reply):
                guard reply.envelope.type == IMEnvelope.okType(IMFrameType.hello) else {
                    continuation.resume(throwing:
                        IMRTCError(.notAuthenticated, "握手应答是 \(reply.envelope.type)"))
                    return
                }
                let ok = self.parseHelloOK(reply.data)
                self.sessionID = ok.sessionID
                self.state = .connected
                self.reconnectAttempt = 0
                self.heartbeat.start(intervalSec: ok.pingIntervalSec)
                IMRTCLog.info("信令已连接", ["uid": ok.uid, "resumed": String(ok.resumed)])
                continuation.resume(returning: ok)
            }
        }
    }

    private func parseHelloOK(_ data: [String: IMJSON]) -> IMHelloOK {
        let limits = data["limits"]?.objectValue ?? [:]
        return IMHelloOK(
            uid: Wire.string(data, "uid"),
            deviceID: Wire.string(data, "device_id"),
            sessionID: Wire.string(data, "session_id"),
            resumed: Wire.bool(data, "resumed"),
            pingIntervalSec: Int(Wire.int(data, "ping_interval_sec")),
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
            if code == .kickedOut { events.onKickedOut?() }
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

        if code == IMCloseCode.kickedOut { events.onKickedOut?() }

        let willReconnect = state != .closed && IMCloseCode.shouldReconnect(code)
        events.onDisconnected?(code, willReconnect)
        guard willReconnect else {
            state = .closed
            return
        }
        state = .reconnecting
        scheduleReconnect()
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
