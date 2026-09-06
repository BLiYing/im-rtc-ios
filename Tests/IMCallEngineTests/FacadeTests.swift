import XCTest
@testable import IMCallEngine

/**
 门面的接线测试。**全程假连接 + 假媒体，不需要网络也不需要模拟器。**

 这一组守的不是状态机（那有一致性向量），而是**门面自己那几条容易漏的接线**——
 Web 端每一条都真漏过一次，症状都是「不报错、界面不动」：

 · 重连的握手结果没人接 → 状态机不知道自己重连了，宿主收不到第二次 didConnect；
 · 应答（`.ok`）没喂回状态机 → 房间永远停在 joining，之后每次 publish 被拒成 2005；
 · 事件与帧的顺序反了 → 宿主先收到房间事件，才被告知有这通电话；
 · 状态机那份空载荷的 onDisconnected 也外发 → 宿主每次断线收到两条，还夹一个假 4403。
 */
final class FacadeTests: XCTestCase {

    // MARK: - 假媒体

    /// FakeMedia 记下门面对媒体层做了什么。**它同时是一份清单**：
    /// 门面只碰下面这些方法，多一个就说明它伸手伸出了 IMMediaAdapter。
    private final class FakeMedia: IMMediaAdapter, @unchecked Sendable {
        var events = IMMediaAdapterEvents()
        private let lock = NSLock()
        private var log: [String] = []
        private var muted: [String: Bool] = [:]

        /// 最后一次收到的「track_id → uid」。**不进 log**：门面每推进一步都会调它一次，
        /// 混进 log 会把「门面碰了哪些方法」这份清单淹掉。
        private var claimed: [String: String] = [:]

        func calls() -> [String] { lock.lock(); defer { lock.unlock() }; return log }
        func claims() -> [String: String] { lock.lock(); defer { lock.unlock() }; return claimed }
        func isMuted(_ cid: String) -> Bool {
            lock.lock(); defer { lock.unlock() }; return muted[cid] ?? false
        }
        private func note(_ what: String) { lock.lock(); log.append(what); lock.unlock() }

        func open(_ events: IMMediaAdapterEvents) {
            self.events = events
            note("open")
        }
        func acquireMicrophone() async throws -> IMLocalTrackInfo {
            note("acquireMic")
            return IMLocalTrackInfo(cid: "mic-1", kind: "audio", source: "microphone")
        }
        func probeMicrophone() async throws { note("probeMic") }
        func startLocalPreview() async throws -> IMLocalTrackInfo {
            note("startLocalPreview")
            return IMLocalTrackInfo(cid: "cam-1", kind: "video", source: "camera")
        }
        func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo {
            note("acquireCam(simulcast=\(simulcast))")
            return IMLocalTrackInfo(cid: "cam-1", kind: "video", source: "camera")
        }
        func createPubOffer() async throws -> String { note("createPubOffer"); return "v=0 pub-offer" }
        func applyPubAnswer(_ sdp: String) async throws { note("applyPubAnswer") }
        func answerSubOffer(_ sdp: String) async throws -> String {
            note("answerSubOffer(\(sdp))")
            return "v=0 sub-answer"
        }
        func addRemoteCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async throws {
            note("addRemoteCandidate(\(pc.wireValue),\(candidate.candidate))")
        }
        func setMuted(_ cid: String, _ isMuted: Bool) {
            lock.lock(); muted[cid] = isMuted; log.append("setMuted(\(cid),\(isMuted))"); lock.unlock()
        }
        func claimRemoteTracks(_ owners: [String: String]) {
            lock.lock(); claimed = owners; lock.unlock()
        }
        func attachRemoteView(_ uid: String, _ view: AnyObject?) {
            note("attachRemote(\(uid),\(view == nil ? "nil" : "view"))")
        }
        func attachLocalView(_ cid: String, _ view: AnyObject?) {
            note("attachLocal(\(cid),\(view == nil ? "nil" : "view"))")
        }
        func setSpeakerOn(_ on: Bool) { note("setSpeakerOn(\(on))") }
        func close() { note("close") }
    }

    /// Recorder 按顺序记下宿主收到的事件。**顺序本身就是断言对象**。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [IMCallEvent] = []
        func add(_ event: IMCallEvent) { lock.lock(); items.append(event); lock.unlock() }
        func names() -> [IMCallEventName] {
            lock.lock(); defer { lock.unlock() }; return items.map(\.name)
        }
        func all() -> [IMCallEvent] { lock.lock(); defer { lock.unlock() }; return items }
        func first(_ name: IMCallEventName) -> IMCallEvent? {
            lock.lock(); defer { lock.unlock() }; return items.first { $0.name == name }
        }
        func count(_ name: IMCallEventName) -> Int {
            lock.lock(); defer { lock.unlock() }; return items.filter { $0.name == name }.count
        }
    }

    // MARK: - 装配

    private struct Harness {
        let engine: IMCallEngine
        let media: FakeMedia
        let events: Recorder
        let sockets: SocketBox
    }

    private func makeEngine() -> Harness {
        let box = SocketBox()
        let media = FakeMedia()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!,
                                  deviceID: "d-1", media: media)
        engine.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        let recorder = Recorder()
        engine.addEventObserver { recorder.add($0) }
        return Harness(engine: engine, media: media, events: recorder, sockets: box)
    }

    /// login 走完一次握手，返回那条假 socket。
    private func login(_ h: Harness, resumed: Bool = false) async throws -> FakeWebSocket {
        async let done: Void = h.engine.login("token-1")
        let ws = try await waitForSocket(h.sockets)
        ws.open()
        let hello = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: hello.reqID, resumed: resumed))
        try await done
        try await settle()
        return ws
    }

    /// settle 等异步事件链走完。门面里每一步都是 Task，得给它们时间落地。
    private func settle(_ rounds: Int = 12) async throws {
        for _ in 0..<rounds { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: - 用例

    func testLoginRaisesConnected() async throws {
        let h = makeEngine()
        _ = try await login(h)

        XCTAssertEqual(h.events.count(.connected), 1)
        XCTAssertEqual(h.events.first(.connected)?.payload["session_id"] as? String, "s-1")
        XCTAssertEqual(h.media.calls().first, "open", "login 时要把媒体层接起来")
    }

    /// **重连那次握手也必须进状态机**。
    ///
    /// 只在 login 里喂 hello.ok 的话：状态机不知道自己重连了，
    /// `resumed == false` 时房间不归零、宿主也收不到第二次 didConnect
    /// （Web 端症状：换票重连成功了，界面一直停在「重连中」）。
    func testReconnectAlsoRaisesConnected() async throws {
        let h = makeEngine()
        let first = try await login(h)

        first.closeFromServer(IMCloseCode.goingAway)
        let next = try await waitForNewSocket(h.sockets, after: first)
        next.open()
        let hello = try await waitForFrame(next, ofType: IMFrameType.hello)
        next.receive(helloOKFrame(reqID: hello.reqID, resumed: true))
        try await settle()

        XCTAssertEqual(h.events.count(.connected), 2, "重连成功也要抛 didConnect")
        XCTAssertEqual(h.events.all().last(where: { $0.name == .connected })?
            .payload["resumed"] as? NSNumber, NSNumber(value: true))
    }

    /// 断线只抛一条 disconnected，**且带得上关闭码**。
    ///
    /// 状态机也有一份 onDisconnected，但它是空载荷的（关闭码不是状态机的事）。
    /// 两边都发的话宿主每次断线收到两条，还会夹进一条**假的 4403**
    /// （因为「鉴权连续失败」复用了 ws_closed_4403 这个内部事件）。
    func testDisconnectedIsRaisedOnceWithCode() async throws {
        let h = makeEngine()
        let ws = try await login(h)

        ws.closeFromServer(IMCloseCode.goingAway, reason: "restart")
        try await settle()

        XCTAssertEqual(h.events.count(.disconnected), 1, "一次断线只该有一条")
        let event = h.events.first(.disconnected)
        XCTAssertEqual(event?.payload["code"] as? NSNumber, NSNumber(value: IMCloseCode.goingAway))
        XCTAssertEqual(event?.payload["will_reconnect"] as? NSNumber, NSNumber(value: true))
    }

    /// 被踢：抛 kickedOut，且那条 disconnected 报的是**真关闭码 4403**。
    func testKickedOutReportsRealCloseCode() async throws {
        let h = makeEngine()
        let ws = try await login(h)

        ws.closeFromServer(IMCloseCode.kickedOut)
        try await settle()

        XCTAssertEqual(h.events.count(.kickedOut), 1)
        XCTAssertEqual(h.events.count(.disconnected), 1)
        XCTAssertEqual(h.events.first(.disconnected)?.payload["code"] as? NSNumber,
                       NSNumber(value: IMCloseCode.kickedOut))
    }

    /// 进房：**`.ok` 必须喂回状态机**，否则房间永远停在 joining。
    func testJoinRoomOKAdvancesTheMachine() async throws {
        let h = makeEngine()
        let ws = try await login(h)

        async let joining: Void = h.engine.joinRoom("r-1", roomToken: "rt-1")
        let join = try await waitForFrame(ws, ofType: IMFrameType.roomJoin)
        // 顺带验一条：发送侧从全默认值起手，auto_subscribe 不能被写成 false（§2.4）。
        XCTAssertEqual(join.data["auto_subscribe"]?.boolValue, true)
        ws.receive("""
        {"type":"room.join.ok","req_id":"\(join.reqID)","ts":1,"data":{\
        "room_id":"r-1","participant_id":"r-1-p1","participants":[],"tracks":[]}}
        """)
        await joining
        try await settle()

        let state = await h.engine.state
        XCTAssertEqual(state.room.state, .joined, "join.ok 没喂回状态机，房间就会卡在 joining")
        XCTAssertEqual(h.events.count(.roomJoined), 1)
    }

    /// 发布：先拿轨道再发 publish，拿到 track_id 之后才发 pub offer（协议 §3.2）。
    func testPublishOrder() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        async let publishing = h.engine.publishMicrophone()
        let publish = try await waitForFrame(ws, ofType: IMFrameType.roomPublish)
        XCTAssertEqual(publish.data["cid"]?.stringValue, "mic-1")
        ws.receive("""
        {"type":"room.publish.ok","req_id":"\(publish.reqID)","ts":1,\
        "data":{"cid":"mic-1","track_id":"t-1"}}
        """)
        let offer = try await waitForFrame(ws, ofType: IMFrameType.roomOffer)
        XCTAssertEqual(offer.data["sdp"]?.stringValue, "v=0 pub-offer",
                       "状态机产不出 SDP，必须由 sender 填真值")
        ws.receive("""
        {"type":"room.answer","req_id":"\(offer.reqID)","ts":1,\
        "data":{"pc":"pub","sdp":"v=0 answer"}}
        """)
        let cid = try await publishing
        try await settle()

        XCTAssertEqual(cid, "mic-1")
        XCTAssertTrue(h.media.calls().contains("acquireMic"))
        XCTAssertTrue(h.media.calls().contains("applyPubAnswer"),
                      "pub answer 要先落到媒体层，再让状态机推进到 published")
    }

    /// 静音走 mute 不走 unpublish，**并且要真的告诉媒体层**。
    func testSetMutedTouchesBothMediaAndSignaling() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)
        try await publishMic(h, ws)

        // **要并发地发起再应答**：`setMuted` 会一直等 `room.mute.ok`，
        // 顺序写的话这里会白等满 10 秒的请求超时，测到的就成了失败路径。
        async let muting: Void = h.engine.setMuted("mic-1", muted: true)
        let mute = try await waitForFrame(ws, ofType: IMFrameType.roomMute)
        ws.receive("""
        {"type":"room.mute.ok","req_id":"\(mute.reqID)","ts":1,"data":{}}
        """)
        await muting

        XCTAssertEqual(mute.data["track_id"]?.stringValue, "t-1")
        XCTAssertEqual(mute.data["muted"]?.boolValue, true)
        XCTAssertTrue(h.media.isMuted("mic-1"), "只发帧不停发包，对端还是能听见")
        XCTAssertEqual(h.events.count(.error), 0, "正常静音不该产生任何 error 事件")
    }

    /// 没有媒体适配器时，推流要以**说得清的** 2005 失败，而不是崩或者发空 SDP。
    ///
    /// 「只要信令、UI 自己画」的宿主不给适配器是**正常用法**，这条路必须体面。
    func testSignalingOnlyEngineRejectsPublish() async throws {
        let box = SocketBox()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1")
        engine.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        async let done: Void = engine.login("token-1")
        let ws = try await waitForSocket(box)
        ws.open()
        let hello = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: hello.reqID))
        try await done

        do {
            _ = try await engine.publishMicrophone()
            XCTFail("没有媒体适配器时不该发布成功")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .invalidState)
            XCTAssertTrue(error.detail.contains("媒体适配器"), "错误要说清缺的是什么")
        }
    }

    /// 远端候选要交给媒体层。**Web 端把这条路整条漏过**：只往上发不往下收，
    /// 下行 PC 永远停在 new，界面上是「格子在、画面黑」，且不报任何错。
    func testRemoteCandidateReachesMedia() async throws {
        let h = makeEngine()
        let ws = try await login(h)

        ws.receive("""
        {"type":"room.ice_candidate","req_id":"","ts":1,"data":{\
        "pc":"sub","candidate":"candidate:1 1 udp 1 127.0.0.1 7881 typ host",\
        "sdp_mid":"0","sdp_mline_index":0}}
        """)
        try await settle()

        XCTAssertTrue(h.media.calls().contains { $0.hasPrefix("addRemoteCandidate(sub,") })
    }

    /// 空候选表示收集结束，**协议要求容忍**（§3.3）——不能当成一个坏候选去报错。
    func testEmptyCandidateIsIgnored() async throws {
        let h = makeEngine()
        let ws = try await login(h)

        ws.receive("""
        {"type":"room.ice_candidate","req_id":"","ts":1,\
        "data":{"pc":"sub","candidate":"","sdp_mid":"","sdp_mline_index":0}}
        """)
        try await settle()

        XCTAssertFalse(h.media.calls().contains { $0.hasPrefix("addRemoteCandidate") })
        XCTAssertEqual(h.events.count(.error), 0)
    }

    /**
     媒体层必须知道**每条下行轨道属于谁**。

     少了这一步，媒体层就只能拿 track_id 当 uid 用，而挂载侧
     `attachView(uid:)` 传的是真 uid——两把钥匙对不上，
     于是**协商全通、首帧照抛，但一格画面都不出来**。真机三人互相看不见就是它。
    */
    func testRemoteTrackOwnerReachesMedia() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        ws.receive("""
        {"type":"room.track_published","req_id":"","ts":1,"data":{\
        "room_id":"r-1","participant_id":"r-1-p2","uid":"alice",\
        "track_id":"t-9","kind":"video","source":"camera","simulcast":false,"muted":false}}
        """)
        try await settle()

        XCTAssertEqual(h.media.claims()["t-9"], "alice")
    }

    /// 离房要把媒体面归零，否则下一次进房带着上一轮的 PeerConnection。
    func testLeaveRoomResetsMedia() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        async let leaving: Void = h.engine.leaveRoom()
        let leave = try await waitForFrame(ws, ofType: IMFrameType.roomLeave)
        ws.receive("""
        {"type":"room.leave.ok","req_id":"\(leave.reqID)","ts":1,"data":{}}
        """)
        await leaving
        try await settle()

        XCTAssertEqual(h.events.count(.roomLeft), 1, "会议没有 callEnd，收尾只能靠 roomLeft")
        XCTAssertTrue(h.media.calls().contains("close"))
    }

    /// delegate 与 block 是**同一个分发点**的两个出口，收到的必须一致。
    func testDelegateAndBlockSeeTheSameEvents() async throws {
        final class Spy: NSObject, IMCallEngineDelegate {
            let lock = NSLock()
            var connected = 0
            func callEngine(_ engine: IMCallEngine, didConnect sessionID: String, resumed: Bool) {
                lock.lock(); connected += 1; lock.unlock()
            }
        }
        let h = makeEngine()
        let spy = Spy()
        h.engine.delegate = spy
        _ = try await login(h)

        XCTAssertEqual(h.events.count(.connected), 1)
        spy.lock.lock()
        let seen = spy.connected
        spy.lock.unlock()
        XCTAssertEqual(seen, 1, "delegate 与 block 只能同时收到或同时收不到")
    }

    /// 退订之后不再收到事件——漏掉 remove 会悄悄泄漏（CONVENTIONS §5 的成对清理）。
    func testRemoveEventObserver() async throws {
        let h = makeEngine()
        let second = Recorder()
        let token = h.engine.addEventObserver { second.add($0) }
        h.engine.removeEventObserver(token)
        _ = try await login(h)

        XCTAssertEqual(second.names(), [], "退订之后不该再收到任何事件")
        XCTAssertEqual(h.events.count(.connected), 1, "另一个观察者不受影响")
    }

    // MARK: - 辅助

    private func joinRoom(_ h: Harness, _ ws: FakeWebSocket) async throws {
        async let joining: Void = h.engine.joinRoom("r-1", roomToken: "rt-1")
        let join = try await waitForFrame(ws, ofType: IMFrameType.roomJoin)
        ws.receive("""
        {"type":"room.join.ok","req_id":"\(join.reqID)","ts":1,"data":{\
        "room_id":"r-1","participant_id":"r-1-p1","participants":[],"tracks":[]}}
        """)
        await joining
        try await settle(4)
    }

    private func publishMic(_ h: Harness, _ ws: FakeWebSocket) async throws {
        async let publishing = h.engine.publishMicrophone()
        let publish = try await waitForFrame(ws, ofType: IMFrameType.roomPublish)
        ws.receive("""
        {"type":"room.publish.ok","req_id":"\(publish.reqID)","ts":1,\
        "data":{"cid":"mic-1","track_id":"t-1"}}
        """)
        let offer = try await waitForFrame(ws, ofType: IMFrameType.roomOffer)
        ws.receive("""
        {"type":"room.answer","req_id":"\(offer.reqID)","ts":1,\
        "data":{"pc":"pub","sdp":"v=0 answer"}}
        """)
        _ = try await publishing
        try await settle(4)
    }

    private func waitForSocket(_ box: SocketBox) async throws -> FakeWebSocket {
        for _ in 0..<200 {
            if let socket = box.get() { return socket }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没有建立连接")
    }

    private func waitForNewSocket(_ box: SocketBox,
                                  after previous: FakeWebSocket) async throws -> FakeWebSocket {
        for _ in 0..<800 {
            if let socket = box.get(), socket !== previous { return socket }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到重连建立的新连接")
    }

    private func waitForFrame(_ ws: FakeWebSocket,
                              ofType type: String) async throws -> IMEnvelope {
        for _ in 0..<400 {
            if let match = ws.frames().last(where: { $0.type == type }) { return match }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到帧 \(type)")
    }
}

/**
 「失败要有出口」这一组。

 两条路以前都是**卡死**：状态机停在中间态，界面永远停在「正在呼叫…」/
 「正在进入会议…」，而之后每一次操作都换回一个没头没尾的错误码。
 */
final class FailureRollbackTests: XCTestCase {

    /// 发起呼叫被拒 → 通话机回 idle，并抛唯一的结束出口。
    func testInviteRejectedRollsBack() {
        var ctx = IMEngineContext()
        let placed = IMEngineMachine.reduce(ctx, .act(op: "call", args: [
            "callee_ids": .array([.string("bob")]),
            "media_type": .string("audio"),
            "is_group": .bool(false),
        ]))
        ctx = placed.state
        XCTAssertEqual(ctx.call.state, .inviting)

        let failed = IMEngineMachine.reduce(ctx, .internalEvent(name: "call_failed"))
        XCTAssertEqual(failed.state.call.state, .idle, "不回 idle 的话之后挂断永远是 1401")
        XCTAssertEqual(failed.emit.map(\.callback), ["onCallEnd"])
        XCTAssertEqual(failed.emit.first?.args["reason"]?.stringValue, "error")
    }

    /// 进房被拒 → 房间机回 idle，**并且抛 onRoomLeft**。
    ///
    /// iOS 上这个分支原先整个没有：FrameLoop 发了 join_failed 但没人接，
    /// 于是进房失败之后这台 Engine 再也进不了任何房间。
    func testJoinRejectedRollsBackAndTellsTheHost() {
        var ctx = IMEngineContext()
        let joining = IMEngineMachine.reduce(ctx, .act(op: "join", args: [
            "room_id": .string("r-1"),
            "room_token": .string("rt"),
            "auto_subscribe": .bool(true),
        ]))
        ctx = joining.state
        XCTAssertEqual(ctx.room.state, .joining)

        let failed = IMEngineMachine.reduce(ctx, .internalEvent(name: "join_failed"))
        XCTAssertEqual(failed.state.room.state, .idle)
        XCTAssertEqual(failed.emit.map(\.callback), ["onRoomLeft"],
                       "只清状态不抛回调的话，会议界面会一直停在「正在进入会议…」")
    }

    /// 退回 idle 之后能重来——这才是「退得出去」的证据。
    func testCanRetryAfterRollback() {
        var ctx = IMEngineContext()
        ctx = IMEngineMachine.reduce(ctx, .act(op: "join", args: [
            "room_id": .string("r-1"), "room_token": .string("rt"),
            "auto_subscribe": .bool(true),
        ])).state
        ctx = IMEngineMachine.reduce(ctx, .internalEvent(name: "join_failed")).state

        let again = IMEngineMachine.reduce(ctx, .act(op: "join", args: [
            "room_id": .string("r-2"), "room_token": .string("rt2"),
            "auto_subscribe": .bool(true),
        ]))
        XCTAssertEqual(again.state.room.state, .joining)
        XCTAssertEqual(again.send.map(\.type), [IMFrameType.roomJoin])
    }
}
