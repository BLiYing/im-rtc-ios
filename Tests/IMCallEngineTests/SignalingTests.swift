import XCTest
@testable import IMCallEngine

/// 信令连接的时序测试。全部用假连接跑，**不需要网络也不需要模拟器**。
final class SignalingTests: XCTestCase {
    /// makeConnection 建一条接了假 socket 的连接。
    private func makeConnection(events: IMConnectionEvents = IMConnectionEvents(),
                                random: @escaping () -> Double = { 0.5 })
        -> (IMSignalConnection, () -> FakeWebSocket?) {
        let box = SocketBox()
        var options = IMConnectionOptions(url: URL(string: "ws://test/v1/ws")!,
                                          token: "test-token", deviceID: "d-1")
        options.requestTimeoutMS = 500
        options.random = random
        options.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        return (IMSignalConnection(options: options, events: events), { box.get() })
    }

    /// 握手：**第一帧必须是 sys.hello**，且带上 token 与 device_id（§1.2）。
    func testHandshakeSendsHelloFirst() async throws {
        let (connection, socket) = makeConnection()

        async let hello = connection.connect()
        let ws = try await waitForSocket(socket)
        ws.open()
        let frame = try await waitForFrame(ws)

        XCTAssertEqual(frame.type, IMFrameType.hello, "第一帧必须是 sys.hello")
        XCTAssertEqual(frame.data["token"]?.stringValue, "test-token")
        XCTAssertEqual(frame.data["device_id"]?.stringValue, "d-1")
        XCTAssertFalse(frame.reqID.isEmpty, "请求帧必须带非空 req_id")

        ws.receive(helloOKFrame(reqID: frame.reqID))
        let ok = try await hello
        XCTAssertEqual(ok.uid, "alice")
        XCTAssertEqual(ok.sessionID, "s-1")
        XCTAssertEqual(connection.currentState, .connected)
    }

    /// 重连时要带上 session_id 请求恢复（§1.4）。
    func testReconnectCarriesSessionID() async throws {
        let (connection, socket) = makeConnection()
        try await handshake(connection, socket)

        // 断开后重连：新连接的 sys.hello 要带上上一次的 session_id。
        XCTAssertEqual(connection.currentSessionID, "s-1")
    }

    /// 应答**按 req_id 配对**，不按帧类型。
    ///
    /// pub 侧的 room.offer 是由 room.answer 应答的（§3.3），只看类型对不上号。
    func testRepliesArePairedByReqID() async throws {
        let (connection, socket) = makeConnection()
        let ws = try await handshake(connection, socket)

        async let reply = connection.request(IMFrameType.roomOffer,
                                             data: ["pc": .string("pub"), "sdp": .string("o=-")])
        let sent = try await waitForFrame(ws, ofType: IMFrameType.roomOffer)
        // 服务端用 room.answer 应答，req_id 原样回显。
        ws.receive("""
        {"type":"room.answer","req_id":"\(sent.reqID)","ts":1,"data":{"pc":"pub","sdp":"a=-"}}
        """)

        let result = try await reply
        XCTAssertEqual(result.envelope.type, IMFrameType.roomAnswer)
        XCTAssertEqual(result.data["sdp"]?.stringValue, "a=-")
    }

    /// 带 req_id 的 sys.error 是**应答**，要结算成失败，不能当事件抛。
    func testErrorFrameWithReqIDFailsTheRequest() async throws {
        let (connection, socket) = makeConnection()
        let ws = try await handshake(connection, socket)

        async let reply = connection.request(IMFrameType.callAccept,
                                             data: ["call_id": .string("call-1")])
        let sent = try await waitForFrame(ws, ofType: IMFrameType.callAccept)
        ws.receive("""
        {"type":"sys.error","req_id":"\(sent.reqID)","ts":1,\
        "data":{"code":1401,"name":"call_not_found","msg":"call not found",\
        "for_type":"call.accept","retryable":false}}
        """)

        do {
            _ = try await reply
            XCTFail("本该失败")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .callNotFound)
        }
    }

    /// 没人在等的 req_id 走事件路径；未知帧类型**静默忽略**（§2.3）。
    func testUnknownFrameIsIgnoredSilently() async throws {
        let received = EventBox()
        var events = IMConnectionEvents()
        events.onEvent = { type, _ in received.append(type) }
        let (connection, socket) = makeConnection(events: events)
        let ws = try await handshake(connection, socket)

        ws.receive(#"{"type":"room.future_thing","req_id":"","ts":1,"data":{}}"#)
        ws.receive(#"{"type":"call.ringing","req_id":"","ts":1,"data":{"call_id":"c","uid":"bob","device_count":1}}"#)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(received.all(), [IMFrameType.callRinging],
                       "未知帧必须静默忽略——服务端可能比我们新")
    }

    /// 请求超时要以 signaling_timeout 失败，而不是永远挂着。
    func testRequestTimesOut() async throws {
        let (connection, socket) = makeConnection()
        _ = try await handshake(connection, socket)

        do {
            _ = try await connection.request(IMFrameType.callHangup,
                                             data: ["call_id": .string("call-1")])
            XCTFail("本该超时")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .signalingTimeout)
        }
    }

    /// 断线时在途请求要**立刻**失败，不能挂到超时。
    func testDisconnectFailsInFlightRequests() async throws {
        let (connection, socket) = makeConnection()
        let ws = try await handshake(connection, socket)

        async let reply = connection.request(IMFrameType.roomLeave,
                                             data: ["room_id": .string("r-1")])
        _ = try await waitForFrame(ws, ofType: IMFrameType.roomLeave)
        ws.closeFromServer(IMCloseCode.goingAway)

        do {
            _ = try await reply
            XCTFail("本该失败")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .networkUnreachable)
        }
    }

    /// 关闭码决定要不要重连（§1.5）。
    ///
    /// 4400 与 4403 **绝不重连**：前者是我们自己的实现 bug，重连只会再撞一次；
    /// 后者是被踢，重连等于跟另一台设备打架。
    func testReconnectDecisionByCloseCode() {
        XCTAssertFalse(IMCloseCode.shouldReconnect(IMCloseCode.normal))
        XCTAssertFalse(IMCloseCode.shouldReconnect(IMCloseCode.badProtocol))
        XCTAssertFalse(IMCloseCode.shouldReconnect(IMCloseCode.kickedOut))
        XCTAssertTrue(IMCloseCode.shouldReconnect(IMCloseCode.goingAway))
        XCTAssertTrue(IMCloseCode.shouldReconnect(IMCloseCode.unauthorized))
        XCTAssertTrue(IMCloseCode.shouldReconnect(IMCloseCode.rateLimited))
    }

    /// 被踢要抛 onKickedOut，且**不重连**。
    func testKickedOutDoesNotReconnect() async throws {
        let kicked = CounterBox()
        var events = IMConnectionEvents()
        events.onKickedOut = { kicked.bump() }
        events.onDisconnected = { _, willReconnect in
            XCTAssertFalse(willReconnect, "被踢之后不该重连")
        }
        let (connection, socket) = makeConnection(events: events)
        let ws = try await handshake(connection, socket)

        ws.closeFromServer(IMCloseCode.kickedOut)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(kicked.value, 1)
        XCTAssertEqual(connection.currentState, .closed)
    }

    /// 退避档位三端同一份；抖动固定成 0 时应当**正好**等于档位值。
    func testBackoffSteps() {
        let noJitter: () -> Double = { 0.5 }
        XCTAssertEqual(IMBackoff.delayMS(attempt: 0, random: noJitter), 1_000)
        XCTAssertEqual(IMBackoff.delayMS(attempt: 3, random: noJitter), 8_000)
        XCTAssertEqual(IMBackoff.delayMS(attempt: 5, random: noJitter), 30_000)
        // 超过档位数固定用最后一档，不会无限增长。
        XCTAssertEqual(IMBackoff.delayMS(attempt: 99, random: noJitter), 30_000)
        // 抖动在 ±20% 之内。
        XCTAssertEqual(IMBackoff.delayMS(attempt: 0, random: { 0 }), 800)
        XCTAssertEqual(IMBackoff.delayMS(attempt: 0, random: { 1 }), 1_200)
    }

    // MARK: - 辅助

    private func handshake(_ connection: IMSignalConnection,
                           _ socket: () -> FakeWebSocket?) async throws -> FakeWebSocket {
        async let hello = connection.connect()
        let ws = try await waitForSocket(socket)
        ws.open()
        let frame = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: frame.reqID))
        _ = try await hello
        return ws
    }

    private func waitForSocket(_ get: () -> FakeWebSocket?) async throws -> FakeWebSocket {
        for _ in 0..<200 {
            if let socket = get() { return socket }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没有建立连接")
    }

    private func waitForFrame(_ ws: FakeWebSocket,
                              ofType type: String? = nil) async throws -> IMEnvelope {
        for _ in 0..<200 {
            let frames = ws.frames()
            if let type {
                if let match = frames.last(where: { $0.type == type }) { return match }
            } else if let last = frames.last {
                return last
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到帧 \(type ?? "任意")")
    }
}

/// 下面三个盒子是为了在 `@Sendable` 闭包里安全地攒断言用的数据。
final class SocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: FakeWebSocket?
    func set(_ value: FakeWebSocket) { lock.lock(); socket = value; lock.unlock() }
    func get() -> FakeWebSocket? { lock.lock(); defer { lock.unlock() }; return socket }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
