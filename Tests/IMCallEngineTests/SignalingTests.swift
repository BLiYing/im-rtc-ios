import XCTest
@testable import IMCallEngine

/// 信令连接的时序测试。全部用假连接跑，**不需要网络也不需要模拟器**。
final class SignalingTests: XCTestCase {
    /// makeConnection 建一条接了假 socket 的连接。
    ///
    /// **返回的是 `SocketBox` 而不是取值闭包**：重连会换一条新 socket，
    /// 「换过了没有」「一共造了几条」这两件事只有盒子本身答得上来。
    private func makeConnection(events: IMConnectionEvents = IMConnectionEvents(),
                                random: @escaping () -> Double = { 0.5 })
        -> (IMSignalConnection, SocketBox) {
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
        return (IMSignalConnection(options: options, events: events), box)
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

    /// **每一次**握手都要抛 onConnected，重连那些也算。
    ///
    /// 门面靠它把 `sys.hello.ok` 喂给状态机。只在 `login()` 里喂一遍的话，
    /// 重连之后状态机不知道自己重连了：`resumed == false` 时房间不归零、
    /// `resumed == true` 时攒下的意图不重放，宿主也收不到第二次 onConnected。
    /// （Web 端真漏过，症状是换票重连成功了界面却停在「重连中」。）
    func testConnectedIsRaisedOnEveryHandshake() async throws {
        let box = EventBox()
        var events = IMConnectionEvents()
        events.onConnected = { ok in box.append("connected:\(ok.resumed)") }
        let (connection, socket) = makeConnection(events: events)
        let first = try await handshake(connection, socket)
        XCTAssertEqual(box.all(), ["connected:false"], "首次握手就该抛一次")

        first.closeFromServer(IMCloseCode.goingAway)
        let next = try await waitForNewSocket(socket, after: first)
        next.open()
        let hello = try await waitForFrame(next, ofType: IMFrameType.hello)
        XCTAssertEqual(hello.data["session_id"]?.stringValue, "s-1", "重连要带上原会话 id")
        next.receive(helloOKFrame(reqID: hello.reqID, resumed: true))
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(box.all(), ["connected:false", "connected:true"],
                       "重连那次握手也必须抛——门面就是靠它把 hello.ok 喂进状态机的")
    }

    /// 连续 3 次 4401 就彻底放弃并抛 onKickedOut（协议 §1.5）。
    ///
    /// **一定要有这个上限**：4401 说的是「这枚 token 不好使」，而重连**带的是同一枚
    /// token**——没有上限就是拿同一把坏钥匙永远敲同一扇门。Web 端实测过：服务端重启
    /// 换了签名密钥，一个没关的标签页重试到第 19 次还在敲，日志里全是 token_invalid。
    ///
    /// 这个用例要真等两档退避（1s + 2s），是本套件里最慢的一个；换来的是
    /// 「废票不会自己敲一整天」这条规则被守住。
    func testConsecutiveAuthFailuresGiveUp() async throws {
        let kicked = CounterBox()
        let lastWillReconnect = CounterBox()
        var events = IMConnectionEvents()
        events.onKickedOut = { kicked.bump() }
        events.onDisconnected = { _, willReconnect in
            if willReconnect { lastWillReconnect.bump() }
        }
        let (connection, socket) = makeConnection(events: events)
        var ws = try await handshake(connection, socket)
        let box = socket

        // 前两次还给机会：换新 token 后重连是可能成功的。
        for _ in 0..<2 {
            let previous = ws
            ws.closeFromServer(IMCloseCode.unauthorized)
            XCTAssertEqual(kicked.value, 0, "还没到上限，不该抛 onKickedOut")
            ws = try await waitForNewSocket(box, after: previous)
            ws.open()
            _ = try await waitForFrame(ws, ofType: IMFrameType.hello)
        }
        XCTAssertEqual(lastWillReconnect.value, 2, "前两次都该说「会重连」")

        // 第 3 次到顶：不再重连，把宿主赶回登录页去换票。
        let madeBefore = box.count
        ws.closeFromServer(IMCloseCode.unauthorized)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(kicked.value, 1)
        XCTAssertEqual(connection.currentState, .closed)
        XCTAssertEqual(lastWillReconnect.value, 2, "到顶那次不该再说「会重连」")

        // 再等过最长一档也不该有新连接。
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(box.count, madeBefore, "放弃之后不该再建连接")
    }

    /// 宿主换的票，下一次重连必须真的带上——这是协议 §1.5 在客户端的落点。
    ///
    /// （「换票同时清零失败计数」那一半由 Web 端的 updateToken 用例守，
    /// 两端同一份逻辑，这里不再多花两档退避去重复它。）
    func testUpdateTokenIsUsedOnNextReconnect() async throws {
        let (connection, socket) = makeConnection()
        let first = try await handshake(connection, socket)

        first.closeFromServer(IMCloseCode.unauthorized)
        // 宿主在这里去换票：重连是已经排好的（第一档 1s），只要赶在它之前调到就行。
        connection.updateToken("token-new")

        // **必须等「另一条」socket**：盒子里一直有上一条，等「有 socket」会立刻拿到旧的，
        // 而对一条已关闭的假 socket 再 open() 会把 connect() 的 continuation 重复唤醒。
        let next = try await waitForNewSocket(socket, after: first)
        next.open()
        let hello = try await waitForFrame(next, ofType: IMFrameType.hello)
        XCTAssertEqual(hello.data["token"]?.stringValue, "token-new")
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
                           _ socket: SocketBox) async throws -> FakeWebSocket {
        async let hello = connection.connect()
        let ws = try await waitForSocket(socket)
        ws.open()
        let frame = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: frame.reqID))
        _ = try await hello
        return ws
    }

    /// waitForNewSocket 等到 box 里换成了**另一条** socket（重连造的那条）。
    ///
    /// 不能只等「有 socket」：box 里一直有上一条，那样会立刻返回旧的。
    private func waitForNewSocket(_ box: SocketBox,
                                  after previous: FakeWebSocket) async throws -> FakeWebSocket {
        for _ in 0..<800 {
            if let socket = box.get(), socket !== previous { return socket }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到重连建立的新连接")
    }

    private func waitForSocket(_ box: SocketBox) async throws -> FakeWebSocket {
        for _ in 0..<200 {
            if let socket = box.get() { return socket }
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
    private var made = 0
    func set(_ value: FakeWebSocket) { lock.lock(); socket = value; made += 1; lock.unlock() }
    func get() -> FakeWebSocket? { lock.lock(); defer { lock.unlock() }; return socket }
    /// count 是**一共造了几条** socket——「放弃之后没有再重连」只能靠它断言。
    var count: Int { lock.lock(); defer { lock.unlock() }; return made }
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
