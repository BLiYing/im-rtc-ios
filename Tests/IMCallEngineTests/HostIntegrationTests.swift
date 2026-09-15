import XCTest
@testable import IMCallEngine

/**
 宿主对接 M1（HOST_INTEGRATION_DESIGN §3.2/§3.3）：三条新一致性向量之外，
 再钉两类向量覆盖不到的行为——

 1. **回落**：`call.connected` 不带 `caller` / `chat_group_id` / `user_data`
    时（旧服务端），状态机要回落到本通 `call.incoming` / `call()` 记下的值。
    三条新向量给的 `call.connected` 一直带着这三个字段，验不到回落分支。
 2. **门面的本地校验**：`chatGroupID` 超限 / 含空白、`userData` 超限时，
    与「名单里有自己」同一个出口——不上线路。
 */
final class HostIntegrationFallbackTests: XCTestCase {

    /// 主叫：`call()` 记下的群号 / user_data，在 `call.connected` 没带时原样回落。
    func testCallerFallsBackToCallOptionsWhenConnectedOmitsThem() {
        var ctx = IMCallContext()
        let started = IMCallMachine.reduce(ctx, .act(op: "call", args: [
            "callee_ids": .array([.string("bob")]),
            "media_type": .string("audio"),
            "is_group": .bool(true),
            "chat_group_id": .string("g-42"),
            "user_data": .string("payload"),
        ]))
        ctx = started.state
        XCTAssertEqual(ctx.chatGroupID, "g-42")
        XCTAssertEqual(ctx.userData, "payload")

        // 旧服务端的 call.connected：不带 caller / chat_group_id / user_data。
        let connected = IMCallMachine.reduce(ctx, .recv(type: IMFrameType.callConnected, data: [
            "call_id": .string("call-1"), "room_id": .string("r-1"), "room_token": .string("tk"),
            "media_type": .string("audio"), "is_group": .bool(true),
            "connected_at_ms": .int(1000), "accepted_by": .string("bob"),
        ]))
        let begin = connected.emit.first { $0.callback == "onCallBegin" }
        XCTAssertEqual(begin?.args["chat_group_id"]?.stringValue, "g-42", "回落到 call() 选项记下的群号")
        XCTAssertEqual(begin?.args["user_data"]?.stringValue, "payload", "回落到 call() 选项记下的 user_data")
        XCTAssertEqual(begin?.args["caller"]?.stringValue, "", "主叫没有可回落的发起人，旧服务端就是空串")
    }

    /// 被叫：`call.incoming` 记下的发起人 / 群号 / user_data，在 `call.connected` 没带时原样回落。
    func testCalleeFallsBackToIncomingWhenConnectedOmitsThem() {
        var ctx = IMCallContext()
        let received = IMCallMachine.reduce(ctx, .recv(type: IMFrameType.callIncoming, data: [
            "call_id": .string("call-1"), "room_id": .string("r-1"), "caller": .string("alice"),
            "callee_ids": .array([.string("bob")]), "media_type": .string("video"),
            "is_group": .bool(true), "chat_group_id": .string("g-9"), "user_data": .string("u-9"),
        ]))
        ctx = received.state
        let accept = IMCallMachine.reduce(ctx, .act(op: "accept"))
        ctx = accept.state

        let connected = IMCallMachine.reduce(ctx, .recv(type: IMFrameType.callConnected, data: [
            "call_id": .string("call-1"), "room_id": .string("r-1"), "room_token": .string("tk"),
            "media_type": .string("video"), "is_group": .bool(true),
            "connected_at_ms": .int(1000), "accepted_by": .string("bob"),
        ]))
        let begin = connected.emit.first { $0.callback == "onCallBegin" }
        XCTAssertEqual(begin?.args["caller"]?.stringValue, "alice", "回落到 call.incoming 记下的发起人")
        XCTAssertEqual(begin?.args["chat_group_id"]?.stringValue, "g-9")
        XCTAssertEqual(begin?.args["user_data"]?.stringValue, "u-9")
    }

    /// `call.connected` 自己带的值永远优先于回落——不是「先到先得」。
    func testConnectedValuesWinOverFallback() {
        var ctx = IMCallContext()
        let started = IMCallMachine.reduce(ctx, .act(op: "call", args: [
            "callee_ids": .array([.string("bob")]), "media_type": .string("audio"),
            "is_group": .bool(true), "chat_group_id": .string("stale"), "user_data": .string("stale"),
        ]))
        ctx = started.state
        let connected = IMCallMachine.reduce(ctx, .recv(type: IMFrameType.callConnected, data: [
            "call_id": .string("call-1"), "room_id": .string("r-1"), "room_token": .string("tk"),
            "media_type": .string("audio"), "is_group": .bool(true),
            "connected_at_ms": .int(1000), "accepted_by": .string("bob"),
            "caller": .string("alice"), "chat_group_id": .string("fresh"), "user_data": .string("fresh"),
        ]))
        let begin = connected.emit.first { $0.callback == "onCallBegin" }
        XCTAssertEqual(begin?.args["chat_group_id"]?.stringValue, "fresh")
        XCTAssertEqual(begin?.args["user_data"]?.stringValue, "fresh")
        XCTAssertEqual(begin?.args["caller"]?.stringValue, "alice")
    }
}

/// 门面的本地校验（HOST_INTEGRATION_DESIGN §3.3）：不合规的 `IMCallOptions` 就地拒掉，不上线路。
final class HostIntegrationValidationTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [IMCallEvent] = []
        func add(_ event: IMCallEvent) { lock.lock(); items.append(event); lock.unlock() }
        func names() -> [IMCallEventName] { lock.lock(); defer { lock.unlock() }; return items.map(\.name) }
        func all() -> [IMCallEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func makeEngine() -> (IMCallEngine, Recorder) {
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: nil)
        let recorder = Recorder()
        engine.addEventObserver { recorder.add($0) }
        return (engine, recorder)
    }

    /// 没登录时 `uid` 是空串，验证走的是**独立于「名单里含自己」的第二道门**。
    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testOversizedChatGroupIDIsRejectedLocally() async throws {
        let (engine, recorder) = makeEngine()
        let options = IMCallOptions(isGroup: true, chatGroupID: String(repeating: "g", count: 65))
        await engine.call(["bob"], mediaType: "audio", options: options)
        try await settle()
        XCTAssertEqual(recorder.names(), [.error, .callEnd], "与「名单里有自己」同一个出口")
        XCTAssertEqual((recorder.all().first?.payload["code"] as? NSNumber)?.intValue,
                       IMErrorCode.badParams.rawValue)
    }

    func testChatGroupIDWithWhitespaceIsRejectedLocally() async throws {
        let (engine, recorder) = makeEngine()
        let options = IMCallOptions(isGroup: true, chatGroupID: "g 42")
        await engine.call(["bob"], mediaType: "audio", options: options)
        try await settle()
        XCTAssertEqual(recorder.names(), [.error, .callEnd])
    }

    func testOversizedUserDataIsRejectedLocally() async throws {
        let (engine, recorder) = makeEngine()
        let options = IMCallOptions(userData: String(repeating: "u", count: 4097))
        await engine.call(["bob"], mediaType: "audio", options: options)
        try await settle()
        XCTAssertEqual(recorder.names(), [.error, .callEnd])
    }

    /// 合规的选项不该被这道本地门拦下——**没有连接**时才轮到 `2007 not_logged_in`。
    func testValidOptionsPassLocalValidation() async throws {
        let (engine, recorder) = makeEngine()
        let options = IMCallOptions(isGroup: true, chatGroupID: "g-42", userData: "ok", timeoutSec: 45)
        await engine.call(["bob"], mediaType: "audio", options: options)
        try await settle()
        // 没有信令连接：状态机走到 idle→inviting，帧发不出去，换回 notLoggedIn + onCallEnd，
        // 而不是本地校验那条 badParams——用错误码区分两条路径。
        XCTAssertEqual((recorder.all().first { $0.name == .error }?.payload["code"] as? NSNumber)?.intValue,
                       IMErrorCode.notLoggedIn.rawValue)
    }
}

/// 门面到线路：`call(_:mediaType:options:)` 真的把三个字段发上去，`joinCall(_:)` 真的发 `call.join`。
final class HostIntegrationWireTests: XCTestCase {

    private func makeEngine() -> (IMCallEngine, SocketBox) {
        let box = SocketBox()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: nil)
        engine.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        return (engine, box)
    }

    private func login(_ engine: IMCallEngine, _ box: SocketBox) async throws -> FakeWebSocket {
        async let done: Void = engine.login("token-1")
        let ws = try await waitForSocket(box)
        ws.open()
        let hello = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: hello.reqID))
        try await done
        return ws
    }

    private func waitForSocket(_ box: SocketBox) async throws -> FakeWebSocket {
        for _ in 0..<200 {
            if let socket = box.get() { return socket }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没有建立连接")
    }

    private func waitForFrame(_ ws: FakeWebSocket, ofType type: String) async throws -> IMEnvelope {
        for _ in 0..<400 {
            if let match = ws.frames().last(where: { $0.type == type }) { return match }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到帧 \(type)")
    }

    func testCallWithOptionsForwardsFieldsToTheWire() async throws {
        let (engine, box) = makeEngine()
        let ws = try await login(engine, box)
        let options = IMCallOptions(isGroup: true, chatGroupID: "g-42", userData: "payload", timeoutSec: 45)
        // **不能直接 await**：`call()` 会等 `call.invite.ok` 回来才返回，不喂应答的话
        // 会一直卡到请求超时（协议 §7.2 的 10 秒）。与 FacadeTests 同一个 `async let` 套路。
        async let placed: Void = engine.call(["bob"], mediaType: "video", options: options)
        let invite = try await waitForFrame(ws, ofType: IMFrameType.callInvite)
        XCTAssertEqual(invite.data["chat_group_id"]?.stringValue, "g-42")
        XCTAssertEqual(invite.data["user_data"]?.stringValue, "payload")
        XCTAssertEqual(invite.data["timeout_sec"]?.intValue, 45)
        XCTAssertEqual(invite.data["is_group"]?.boolValue, true)
        ws.receive("""
        {"type":"call.invite.ok","req_id":"\(invite.reqID)","ts":1,\
        "data":{"call_id":"call-1","room_id":"r-1","invited_at_ms":1}}
        """)
        try await placed
    }

    /// `timeoutSec == 0`（默认值）不该把线路默认值 30 覆盖成 0。
    func testDefaultTimeoutSecIsNotSentAsZero() async throws {
        let (engine, box) = makeEngine()
        let ws = try await login(engine, box)
        async let placed: Void = engine.call(["bob"], mediaType: "audio", options: IMCallOptions())
        let invite = try await waitForFrame(ws, ofType: IMFrameType.callInvite)
        XCTAssertEqual(invite.data["timeout_sec"]?.intValue, 30, "0 = 用协议默认值，不是真的发 0")
        ws.receive("""
        {"type":"call.invite.ok","req_id":"\(invite.reqID)","ts":1,\
        "data":{"call_id":"call-1","room_id":"r-1","invited_at_ms":1}}
        """)
        try await placed
    }

    func testJoinCallSendsCallJoinWithTheCallID() async throws {
        let (engine, box) = makeEngine()
        let ws = try await login(engine, box)
        async let joined: Void = engine.joinCall("call-77a1")
        let join = try await waitForFrame(ws, ofType: IMFrameType.callJoin)
        XCTAssertEqual(join.data["call_id"]?.stringValue, "call-77a1")
        ws.receive("""
        {"type":"call.join.ok","req_id":"\(join.reqID)","ts":1,"data":{}}
        """)
        try await joined
    }
}
