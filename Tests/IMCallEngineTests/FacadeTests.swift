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
        func stopLocalPreview() { note("stopLocalPreview") }
        func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo {
            note("acquireCam(simulcast=\(simulcast))")
            return IMLocalTrackInfo(cid: "cam-1", kind: "video", source: "camera")
        }
        func createPubOffer() async throws -> String { note("createPubOffer"); return "v=0 pub-offer" }
        func restartPubICE() { note("restartPubICE") }
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
        func switchCamera() async { note("switchCamera") }
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

    /*
     **会话恢复之后必须重新协商上行**（协议 §1.4：客户端的 pub PC 若已失效
     则重发 `room.offer{pc:"pub"}`）。

     这一条不能只挂在「PC 判 failed 的那一刻」：网一断信令也跟着断，房间立刻变成
     `reconnecting`，而 PC 要等约 30 秒才判 `failed`——那时 `restart_pub_ice`
     会被状态机以 `invalid_state` 拒掉，且它**不进 bufferedOps**，于是永远丢失。
     真机 2026-09-07 抓到的正是这一幕：`动作被状态机本地拒绝 op=restart_pub_ice
     room_state=reconnecting`，ICE 自愈在它唯一该生效的场景里等于不存在。
    */
    func testResumeRenegotiatesTheUplink() async throws {
        let h = makeEngine()
        let first = try await login(h)
        try await joinRoom(h, first)
        first.closeFromServer(IMCloseCode.goingAway)
        let next = try await waitForNewSocket(h.sockets, after: first)
        next.open()
        let hello = try await waitForFrame(next, ofType: IMFrameType.hello)
        next.receive(helloOKFrame(reqID: hello.reqID, resumed: true))
        try await settle()

        XCTAssertTrue(h.media.calls().contains("restartPubICE"),
                      "恢复后要让下一个上行 offer 带上 ICE restart")
        // 光置位不发帧等于没做——必须真的补一条 room.offer{pc:"pub"} 到**新那条连接**上。
        let offer = next.frames().last(where: { $0.type == IMFrameType.roomOffer })
        XCTAssertNotNil(offer, "恢复后没补协商帧")
        XCTAssertEqual(offer?.data["pc"]?.stringValue, "pub")
    }

    /// 恢复失败就不该重协商：那时房间已归零，发上去只会换回 1203。
    func testFailedResumeDoesNotRenegotiate() async throws {
        let h = makeEngine()
        let first = try await login(h)
        try await joinRoom(h, first)

        first.closeFromServer(IMCloseCode.goingAway)
        let next = try await waitForNewSocket(h.sockets, after: first)
        next.open()
        let hello = try await waitForFrame(next, ofType: IMFrameType.hello)
        next.receive(helloOKFrame(reqID: hello.reqID, resumed: false))
        try await settle()

        XCTAssertFalse(h.media.calls().contains("restartPubICE"))
        XCTAssertNil(next.frames().last(where: { $0.type == IMFrameType.roomOffer }),
                     "恢复失败时房间已归零，不该再发协商帧")
    }

    /*
     **重试节奏不能没有尽头**（协议 §7.2）。

     一律自愈、永不上报的话，宿主从头到尾收不到任何信号：上行永久失败，
     对端格子已经黑了、计时器还在走，而界面上一切正常。
     连续 3 次重启后仍 failed 抛一次 2006；之后继续重试但不再重复抛。
    */
    func testPubIceGivesUpAndReportsAfterThreeRestarts() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        for _ in 0..<3 { h.media.events.onConnectionStateChange?(.pub, "failed") }
        try await settle()

        XCTAssertEqual(h.events.count(.error), 1, "第 3 次才放弃，且只抛一次")
        XCTAssertEqual(h.events.first(.error)?.payload["code"] as? NSNumber,
                       NSNumber(value: IMErrorCode.mediaNegotiationFailed.rawValue))

        // 放弃是「告诉宿主」，不是「不救了」——后面照样重启，但不再重复抛。
        h.media.events.onConnectionStateChange?(.pub, "failed")
        try await settle()
        XCTAssertEqual(h.events.count(.error), 1, "同一轮只抛一次")
        XCTAssertEqual(h.media.calls().filter { $0 == "restartPubICE" }.count, 4,
                       "上报之后仍在继续自愈")
    }

    /// 前两次不抛——那多半只是切网 / 锁屏的一次抖动，报了等于误报「通话废了」。
    func testPubIceDoesNotReportOnTransientFailures() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        h.media.events.onConnectionStateChange?(.pub, "failed")
        h.media.events.onConnectionStateChange?(.pub, "failed")
        try await settle()

        XCTAssertEqual(h.events.count(.error), 0, "抖动不该惊动宿主")
    }

    /// 救回来过就是新一轮，不该拿旧账凑够 3 次。
    func testPubIceCounterResetsAfterRecovery() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        h.media.events.onConnectionStateChange?(.pub, "failed")
        h.media.events.onConnectionStateChange?(.pub, "failed")
        h.media.events.onConnectionStateChange?(.pub, "connected")
        h.media.events.onConnectionStateChange?(.pub, "failed")
        h.media.events.onConnectionStateChange?(.pub, "failed")
        try await settle()

        XCTAssertEqual(h.events.count(.error), 0, "connected 之后要重新计数")
    }

    /// sub 那条我们救不了（offerer 是服务端，§3.3），所以不重启，但必须立刻上报。
    func testSubIceFailureReportsImmediately() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)
        let restartsBefore = h.media.calls().filter { $0 == "restartPubICE" }.count

        h.media.events.onConnectionStateChange?(.sub, "failed")
        try await settle()

        XCTAssertEqual(h.events.count(.error), 1, "sub 救不了就得立即上报")
        XCTAssertEqual(h.events.first(.error)?.payload["code"] as? NSNumber,
                       NSNumber(value: IMErrorCode.mediaNegotiationFailed.rawValue))
        XCTAssertEqual(h.media.calls().filter { $0 == "restartPubICE" }.count, restartsBefore,
                       "不该替服务端重启——插手只会 glare")
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
        // 顺带验一条：发送侧从全默认值起手，auto_subscribe 不能被写成空串（§2.4）。
        XCTAssertEqual(join.data["auto_subscribe"]?.stringValue, "all")
        ws.receive("""
        {"type":"room.join.ok","req_id":"\(join.reqID)","ts":1,"data":{\
        "room_id":"r-1","participant_id":"r-1-p1","participants":[],"tracks":[]}}
        """)
        try await joining
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
        try await muting

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
        // 候选只属于某个房间：**不在房里时迟到的候选会被丢掉**（见下一条用例），所以先进房。
        try await joinRoom(h, ws)

        ws.receive("""
        {"type":"room.ice_candidate","req_id":"","ts":1,"data":{\
        "pc":"sub","candidate":"candidate:1 1 udp 1 127.0.0.1 7881 typ host",\
        "sdp_mid":"0","sdp_mline_index":0}}
        """)
        try await settle()

        XCTAssertTrue(h.media.calls().contains { $0.hasPrefix("addRemoteCandidate(sub,") })
    }

    /**
     红键看门狗到点 → `forceEnd()`。复现 2026-09-13 14:53 frank 那一刻的形状：
     `call.connected` 到了、`room.join` 发出去还没回，这时强制收场。

     三件事：结束帧**不等 join 回来**就上线路；本地收场只抛一次 onCallEnd；
     迟到的 join.ok 不认领、补发 room.leave，迟到的候选不把 PC 建回来。
     */
    func testForceEndHangsUpWhileJoinIsInFlight() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        ws.receive("""
        {"type":"call.incoming","req_id":"","ts":1,"data":{\
        "call_id":"c-1","room_id":"r-1","caller":"bob","callee_ids":["alice"],\
        "media_type":"video","is_group":true,"timeout_sec":30,"invited_at_ms":1,"user_data":""}}
        """)
        try await settle(4)

        async let accepting: Void = h.engine.accept()
        let accept = try await waitForFrame(ws, ofType: IMFrameType.callAccept)
        ws.receive("""
        {"type":"call.accept.ok","req_id":"\(accept.reqID)","ts":1,"data":{}}
        """)
        try await accepting
        ws.receive("""
        {"type":"call.connected","req_id":"","ts":1,"data":{\
        "call_id":"c-1","room_id":"r-1","room_token":"rt-1","media_type":"video",\
        "is_group":true,"connected_at_ms":1,"accepted_by":"alice"}}
        """)
        let join = try await waitForFrame(ws, ofType: IMFrameType.roomJoin) // 故意不回

        h.engine.forceEnd()

        let hangup = try await waitForFrame(ws, ofType: IMFrameType.callHangup)
        XCTAssertEqual(hangup.data["call_id"]?.stringValue, "c-1")
        try await settle()
        XCTAssertEqual(h.events.count(.callEnd), 1)
        XCTAssertEqual(h.events.first(.callEnd)?.payload["reason"] as? String, "hangup")
        XCTAssertTrue(h.media.calls().contains("close"), "摄像头、麦克风要跟着关")

        // 服务端随后的 call.ended、迟到的 join.ok、迟到的候选，一个都不能把这一场捡回来。
        ws.receive("""
        {"type":"call.ended","req_id":"","ts":1,"data":{"call_id":"c-1","room_id":"r-1",\
        "reason":"hangup","duration_sec":3,"ended_by":"alice"}}
        """)
        ws.receive("""
        {"type":"room.join.ok","req_id":"\(join.reqID)","ts":1,"data":{\
        "room_id":"r-1","participant_id":"r-1-p6","participants":[],"tracks":[]}}
        """)
        let leave = try await waitForFrame(ws, ofType: IMFrameType.roomLeave)
        XCTAssertEqual(leave.data["room_id"]?.stringValue, "r-1", "服务端已经放他进房了，得退出来")
        ws.receive("""
        {"type":"room.leave.ok","req_id":"\(leave.reqID)","ts":1,"data":{}}
        """)
        ws.receive("""
        {"type":"room.ice_candidate","req_id":"","ts":1,"data":{\
        "pc":"sub","candidate":"candidate:1 1 udp 1 127.0.0.1 7881 typ host",\
        "sdp_mid":"0","sdp_mline_index":0}}
        """)
        try await settle()

        XCTAssertEqual(h.events.count(.callEnd), 1, "服务端那条 call.ended 不能再抛一次")
        XCTAssertEqual(h.events.count(.roomJoined), 0)
        XCTAssertEqual(h.events.count(.roomLeft), 0, "补发的 leave 是善后，不是宿主要知道的离房")
        XCTAssertFalse(h.media.calls().contains { $0.hasPrefix("addRemoteCandidate") })
    }

    /// 拨出后 `call.invite.ok` 还没回来就强制收场：本地立刻收掉；invite.ok 回来时补发 cancel，
    /// 被叫才不会一直响到超时。
    func testForceEndWhileInviteInFlightCancelsOnceTheInviteLands() async throws {
        let h = makeEngine()
        let ws = try await login(h)

        async let calling: String = h.engine.call(["bob"], mediaType: "audio")
        let invite = try await waitForFrame(ws, ofType: IMFrameType.callInvite) // 故意不回

        h.engine.forceEnd()
        try await settle()
        XCTAssertEqual(h.events.count(.callEnd), 1)
        XCTAssertEqual(h.events.first(.callEnd)?.payload["reason"] as? String, "cancel")
        XCTAssertFalse(ws.frames().contains { $0.type == IMFrameType.callCancel }, "没有 call_id，此刻发不了")

        ws.receive("""
        {"type":"call.invite.ok","req_id":"\(invite.reqID)","ts":1,"data":{"call_id":"c-9","room_id":"r-9"}}
        """)
        let cancel = try await waitForFrame(ws, ofType: IMFrameType.callCancel)
        XCTAssertEqual(cancel.data["call_id"]?.stringValue, "c-9")
        ws.receive("""
        {"type":"call.cancel.ok","req_id":"\(cancel.reqID)","ts":1,"data":{}}
        """)
        _ = try await calling
        try await settle()
        XCTAssertEqual(h.events.count(.callEnd), 1, "补发 cancel 是善后，不能再抛一次结束")
    }

    /// 拨出后 invite.ok 还没回来就取消：线路上先不出 cancel、宿主不收 error；invite.ok 一回来立刻补发。
    func testCancelWhileInviteInFlightIsSentOnceTheInviteLands() async throws {
        let h = makeEngine()
        let ws = try await login(h)

        async let calling: String = h.engine.call(["bob"], mediaType: "audio")
        let invite = try await waitForFrame(ws, ofType: IMFrameType.callInvite) // 故意不回

        try await h.engine.cancel()
        try await settle(4)
        XCTAssertFalse(ws.frames().contains { $0.type == IMFrameType.callCancel }, "没有 call_id，先不发")
        XCTAssertEqual(h.events.count(.error), 0, "不许为一个发不了的帧给宿主报错")

        ws.receive("""
        {"type":"call.invite.ok","req_id":"\(invite.reqID)","ts":1,"data":{"call_id":"c-8","room_id":"r-8"}}
        """)
        let cancel = try await waitForFrame(ws, ofType: IMFrameType.callCancel)
        XCTAssertEqual(cancel.data["call_id"]?.stringValue, "c-8")
        ws.receive("""
        {"type":"call.cancel.ok","req_id":"\(cancel.reqID)","ts":1,"data":{}}
        """)
        _ = try await calling
        try await settle(4)
        XCTAssertEqual(h.events.count(.error), 0)
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
        try await leaving
        try await settle()

        XCTAssertEqual(h.events.count(.roomLeft), 1, "会议没有 callEnd，收尾只能靠 roomLeft")
        XCTAssertTrue(h.media.calls().contains("close"))
    }

    /// 进房前关摄像头（设计 v3.7 第 6 步）：**同步**交给媒体层停采集，一帧信令都不发。
    ///
    /// 同步是断言对象：调用返回时媒体层就已经收到了，随后的 `startLocalPreview` 不会跑到它前面去。
    func testStopLocalPreviewReachesMediaSynchronously() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        let framesBefore = ws.sent.count

        h.engine.stopLocalPreview()

        XCTAssertEqual(h.media.calls().last, "stopLocalPreview")
        try await settle()
        XCTAssertEqual(ws.sent.count, framesBefore, "停预览是本地的事，不该惊动服务端")
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

    // MARK: - callDidEnd / activeSpeakersDidChange / networkQualityDidChange 的强类型（2026-09-15）

    private final class TypedSpy: NSObject, IMCallEngineDelegate {
        let lock = NSLock()
        var endedReason: IMCallEndReason?
        var speakers: [IMSpeaker] = []
        var quality: [IMNetworkQuality] = []
        func callEngine(_ engine: IMCallEngine, callDidEnd callID: String, reason: IMCallEndReason,
                        durationSec: Int, endedBy: String) {
            lock.lock(); endedReason = reason; lock.unlock()
        }
        func callEngine(_ engine: IMCallEngine, activeSpeakersDidChange speakers: [IMSpeaker]) {
            lock.lock(); self.speakers = speakers; lock.unlock()
        }
        func callEngine(_ engine: IMCallEngine, networkQualityDidChange entries: [IMNetworkQuality]) {
            lock.lock(); self.quality = entries; lock.unlock()
        }
    }

    /// `callDidEnd` 的 `reason` 折成强类型：认识的线路值精确映射，**不认识的一律折成 `.error`**——
    /// 直接喂 `dispatcher`，不需要真的走完一通电话。
    func testCallEndReasonIsTypedAndUnknownFallsBackToError() async throws {
        let h = makeEngine()
        let spy = TypedSpy()
        h.engine.delegate = spy

        h.engine.dispatcher.emit(IMEmittedEvent("onCallEnd", [
            "call_id": .string("c-1"), "reason": .string("busy"),
            "duration_sec": .int(0), "ended_by": .string(""),
        ]))
        try await settle(2)
        spy.lock.lock(); XCTAssertEqual(spy.endedReason, .busy); spy.lock.unlock()

        h.engine.dispatcher.emit(IMEmittedEvent("onCallEnd", [
            "call_id": .string("c-2"), "reason": .string("something_new_in_2027"),
            "duration_sec": .int(0), "ended_by": .string(""),
        ]))
        try await settle(2)
        spy.lock.lock(); XCTAssertEqual(spy.endedReason, .error, "不认识的线路值要折成 .error，不能崩")
        spy.lock.unlock()
    }

    /// `activeSpeakersDidChange` / `networkQualityDidChange` 的元素折成强类型，
    /// 字段与线路上的 `uid`/`volume`/`level` 一一对应。
    func testActiveSpeakersAndNetworkQualityAreTyped() async throws {
        let h = makeEngine()
        let spy = TypedSpy()
        h.engine.delegate = spy

        h.engine.dispatcher.emit(IMEmittedEvent("onActiveSpeakers", [
            "speakers": .array([.object(["uid": .string("alice"), "volume": .int(80)])]),
        ]))
        h.engine.dispatcher.emit(IMEmittedEvent("onNetworkQuality", [
            "entries": .array([.object(["uid": .string("bob"), "level": .int(3)])]),
        ]))
        try await settle(2)

        spy.lock.lock()
        XCTAssertEqual(spy.speakers.map(\.uid), ["alice"])
        XCTAssertEqual(spy.speakers.map(\.volume), [80])
        XCTAssertEqual(spy.quality.map(\.uid), ["bob"])
        XCTAssertEqual(spy.quality.map(\.level), [3])
        spy.lock.unlock()
    }

    // MARK: - destroy（2026-09-15：终态销毁）

    /// destroy 断开 delegate、撤掉全部 block 观察者——之后再有内部事件也不该送到宿主手里。
    func testDestroyDisconnectsDelegateAndObservers() async throws {
        let h = makeEngine()
        let spy = TypedSpy()
        h.engine.delegate = spy
        let countBefore = h.events.names().count

        await h.engine.destroy()
        XCTAssertNil(h.engine.delegate, "destroy 之后 delegate 要断开")

        // emitLocalError 是门面内部方法（@testable），借它验证「撤观察者」真的生效，
        // 不用等一整套信令握手。
        h.engine.emitLocalError(.internalError)
        try await settle(2)
        XCTAssertEqual(h.events.names().count, countBefore, "撤观察者之后不该再收到任何事件")
    }

    /// destroy 之后是终态：不能借同一个实例复活，`login` 继续抛 `invalid_state`。
    func testLoginAfterDestroyThrowsInvalidState() async throws {
        let h = makeEngine()
        await h.engine.destroy()

        do {
            try await h.engine.login("token-2")
            XCTFail("destroy 之后不该还能登录")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .invalidState)
        }
    }

    /// destroy 之后 `publishMicrophone` 这类经 `requireMedia()` 的方法同样抛 `invalid_state`，
    /// 与「没有媒体适配器」共用一条错误面。
    func testPublishAfterDestroyThrowsInvalidState() async throws {
        let h = makeEngine()
        _ = try await login(h)
        await h.engine.destroy()

        do {
            _ = try await h.engine.publishMicrophone()
            XCTFail("destroy 之后不该还能推流")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .invalidState)
        }
    }

    /// 可重复调用：第二次 destroy 不该崩，也不该改变已经断开的状态。
    func testDestroyIsIdempotent() async throws {
        let h = makeEngine()
        _ = try await login(h)
        await h.engine.destroy()
        await h.engine.destroy()
        XCTAssertNil(h.engine.delegate)
    }

    // MARK: - openMicrophone / closeMicrophone / openCamera / closeCamera（2026-09-15）

    /// 没有媒体适配器时，跟 `publishMicrophone` 一样以 2005 失败，不是崩或静默忽略。
    func testOpenMicrophoneWithoutMediaAdapterThrowsInvalidState() async throws {
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
            try await engine.openMicrophone()
            XCTFail("没有媒体适配器时不该开麦成功")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .invalidState)
        }
    }

    /// 第一次 `openMicrophone` 真的发布；已经发布过的第二次只取消静音，不重新 acquire/publish
    /// （协议 §3.2：反复开关走 unpublish 会触发重协商风暴）。
    func testOpenMicrophonePublishesOnceThenOnlyUnmutes() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        async let opening: Void = h.engine.openMicrophone()
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
        try await opening
        try await settle(4)

        XCTAssertTrue(h.media.calls().contains("acquireMic"), "第一次要真的发布")
        let acquireCountBefore = h.media.calls().filter { $0 == "acquireMic" }.count

        // 已经发布过：这一次走 setMuted，同样要等 room.mute.ok，不能顺序写。
        async let reopening: Void = h.engine.openMicrophone()
        let mute = try await waitForFrame(ws, ofType: IMFrameType.roomMute)
        ws.receive("""
        {"type":"room.mute.ok","req_id":"\(mute.reqID)","ts":1,"data":{}}
        """)
        try await reopening
        try await settle(2)

        XCTAssertEqual(h.media.calls().filter { $0 == "acquireMic" }.count, acquireCountBefore,
                       "已经发布过就不该再 acquire 一次")
        XCTAssertTrue(h.media.calls().contains("setMuted(mic-1,false)"), "第二次只是取消静音")
    }

    /// 混用：先用 `publishMicrophone`（高级接口）发布，再调 `openMicrophone`（便利接口）。
    /// 两条入口认的是同一份「发布过没有」，`openMicrophone` 必须认得出已经发布过，
    /// 只取消静音，**不能再发布一路**——这条是本仓自己的账，不看是谁触发的发布。
    func testOpenMicrophoneAfterPublishMicrophoneOnlyUnmutes() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)
        try await publishMic(h, ws)

        XCTAssertEqual(h.media.calls().filter { $0 == "acquireMic" }.count, 1,
                       "publishMicrophone 已经发布过一次")

        async let opening: Void = h.engine.openMicrophone()
        let mute = try await waitForFrame(ws, ofType: IMFrameType.roomMute)
        ws.receive("""
        {"type":"room.mute.ok","req_id":"\(mute.reqID)","ts":1,"data":{}}
        """)
        try await opening
        try await settle(2)

        XCTAssertEqual(h.media.calls().filter { $0 == "acquireMic" }.count, 1,
                       "openMicrophone 不该再发布一路")
        XCTAssertEqual(ws.frames().filter { $0.type == IMFrameType.roomPublish }.count, 1,
                       "全程只该有 publishMicrophone 那一次 room.publish")
        XCTAssertTrue(h.media.calls().contains("setMuted(mic-1,false)"), "只应该取消静音")
    }

    /// `closeMicrophone` 对已发布的轨道只静音、不 unpublish；没发布过就什么都不做。
    func testCloseMicrophoneMutesWithoutUnpublishAndNoOpsWhenNotPublished() async throws {
        let h = makeEngine()

        // 没发布过：空操作，媒体层一次都不该被碰。
        await h.engine.closeMicrophone()
        XCTAssertEqual(h.media.calls(), [], "没发布过就什么都不该碰")

        let ws = try await login(h)
        try await joinRoom(h, ws)
        async let opening: Void = h.engine.openMicrophone()
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
        try await opening
        try await settle(4)

        // `setMuted` 会等 `room.mute.ok`——跟 `testSetMutedTouchesBothMediaAndSignaling` 同一个
        // 理由，必须并发地发起再应答，顺序写会白等满请求超时。
        async let closing: Void = h.engine.closeMicrophone()
        let mute = try await waitForFrame(ws, ofType: IMFrameType.roomMute)
        ws.receive("""
        {"type":"room.mute.ok","req_id":"\(mute.reqID)","ts":1,"data":{}}
        """)
        await closing
        try await settle(2)

        XCTAssertEqual(mute.data["muted"]?.boolValue, true)
        XCTAssertTrue(h.media.isMuted("mic-1"))
        XCTAssertNil(ws.frames().first(where: { $0.type == IMFrameType.roomUnpublish }),
                     "close 不是 unpublish")
    }

    /// `openCamera` 与 `openMicrophone` 同一个道理：第一次真发布，第二次只取消静音。
    func testOpenCameraPublishesOnceThenOnlyUnmutes() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        async let opening: Void = h.engine.openCamera()
        let publish = try await waitForFrame(ws, ofType: IMFrameType.roomPublish)
        ws.receive("""
        {"type":"room.publish.ok","req_id":"\(publish.reqID)","ts":1,\
        "data":{"cid":"cam-1","track_id":"t-1"}}
        """)
        let offer = try await waitForFrame(ws, ofType: IMFrameType.roomOffer)
        ws.receive("""
        {"type":"room.answer","req_id":"\(offer.reqID)","ts":1,\
        "data":{"pc":"pub","sdp":"v=0 answer"}}
        """)
        try await opening
        try await settle(4)

        XCTAssertTrue(h.media.calls().contains(where: { $0.hasPrefix("acquireCam") }))
        let acquireCountBefore = h.media.calls().filter { $0.hasPrefix("acquireCam") }.count

        async let reopening: Void = h.engine.openCamera()
        let mute = try await waitForFrame(ws, ofType: IMFrameType.roomMute)
        ws.receive("""
        {"type":"room.mute.ok","req_id":"\(mute.reqID)","ts":1,"data":{}}
        """)
        try await reopening
        try await settle(2)

        XCTAssertEqual(h.media.calls().filter { $0.hasPrefix("acquireCam") }.count,
                       acquireCountBefore, "已经发布过就不该再 acquire 一次")
        XCTAssertTrue(h.media.calls().contains("setMuted(cam-1,false)"))
    }

    /// `closeCamera` 没发布过是空操作。
    func testCloseCameraNoOpsWhenNotPublished() async throws {
        let h = makeEngine()
        await h.engine.closeCamera()
        XCTAssertEqual(h.media.calls(), [])
    }

    /// 通话结束之后，`openMicrophone`/`openCamera` 的「已发布」记账要归零——
    /// 否则下一通电话会把上一通的 cid 当成还发布着，`setMuted` 一个不存在的 track
    /// 等于什么都没发生（真机上就是「按钮开着但对端听不见」）。
    func testMediaSwitchBookkeepingResetsAfterCallEnd() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        async let opening: Void = h.engine.openMicrophone()
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
        try await opening
        try await settle(4)

        // 模拟这一场结束（不需要真的走完挂断信令，直接喂 onCallEnd 即可——记账靠的是
        // 这个事件名，不是通话状态机本身）。
        h.engine.dispatcher.emit(IMEmittedEvent("onCallEnd", [
            "call_id": .string("c-1"), "reason": .string("hangup"),
            "duration_sec": .int(3), "ended_by": .string(""),
        ]))
        try await settle(2)

        // 记账归零之后再 open 一次：状态机仍是 joined（这里没走真的挂断信令），
        // 所以还是要走一遍完整的 publish/offer round trip——断言的是「有没有重新 acquire」，
        // 不是「这一次网络流程长什么样」。
        let acquireCountBefore = h.media.calls().filter { $0 == "acquireMic" }.count
        async let reopening: Void = h.engine.openMicrophone()
        // 发布方法在 publish.ok 时就返回（结果只管直接那一帧），上一轮的帧还在列表里——按 req_id 排除掉。
        let republish = try await waitForFrame(ws, ofType: IMFrameType.roomPublish, excludingReqID: publish.reqID)
        ws.receive("""
        {"type":"room.publish.ok","req_id":"\(republish.reqID)","ts":1,\
        "data":{"cid":"mic-1","track_id":"t-2"}}
        """)
        let reoffer = try await waitForFrame(ws, ofType: IMFrameType.roomOffer, excludingReqID: offer.reqID)
        ws.receive("""
        {"type":"room.answer","req_id":"\(reoffer.reqID)","ts":1,\
        "data":{"pc":"pub","sdp":"v=0 answer"}}
        """)
        try await reopening
        try await settle(2)

        XCTAssertGreaterThan(h.media.calls().filter { $0 == "acquireMic" }.count, acquireCountBefore,
                             "通话结束后记账要归零，下一次 open 得重新发布")
    }

    // MARK: - 辅助

    /*
      **两条轨道连着发布时，pub offer 必须一个一个来。**

      两个 offer 一起在飞：offer#2 的 setLocalDescription 覆盖掉 offer#1，
      answer#1 回来把状态推回 stable，answer#2 再来就是
      `Called in wrong state: stable (INVALID_STATE)` + `error 1501`
      ——真机 2026-09-08 的 iOS 日志里就是这一串。

      「帧泵是 actor 所以串行」挡不住：`request` 只等到 `room.offer.ok`，
      answer 是随后一条独立的帧，整个回合不在串行范围内。
    */
    func testSecondPublishWaitsForTheFirstPubAnswer() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        // 第一条轨道：publish.ok 之后会发出 offer#1，**先不给它 answer**。
        async let firstPublish = h.engine.publishMicrophone()
        let publish1 = try await waitForFrame(ws, ofType: IMFrameType.roomPublish)
        ws.receive("""
        {"type":"room.publish.ok","req_id":"\(publish1.reqID)","ts":1,\
        "data":{"cid":"mic-1","track_id":"t-1"}}
        """)
        let offer1 = try await waitForFrame(ws, ofType: IMFrameType.roomOffer)

        // 第二条轨道在 answer#1 之前完成 publish——状态机会再要一帧 offer。
        async let secondPublish = h.engine.publishCamera()
        let publish2 = try await waitForFrame(ws, ofType: IMFrameType.roomPublish)
        ws.receive("""
        {"type":"room.publish.ok","req_id":"\(publish2.reqID)","ts":1,\
        "data":{"cid":"cam-1","track_id":"t-2"}}
        """)
        try await settle(6)

        let offersBeforeAnswer = ws.frames().filter { $0.type == IMFrameType.roomOffer }
        XCTAssertEqual(offersBeforeAnswer.count, 1,
                       "answer#1 还没回来就发第二个 offer——两个一起在飞就是 INVALID_STATE")

        // answer#1 落地之后，排队的那一个才补出去。
        ws.receive("""
        {"type":"room.answer","req_id":"\(offer1.reqID)","ts":1,\
        "data":{"pc":"pub","sdp":"v=0 answer"}}
        """)
        try await settle(8)

        let offersAfter = ws.frames().filter { $0.type == IMFrameType.roomOffer }
        XCTAssertEqual(offersAfter.count, 2, "排队的那个 offer 必须补出去，不能吞掉")

        if let offer2 = offersAfter.last {
            ws.receive("""
            {"type":"room.answer","req_id":"\(offer2.reqID)","ts":1,\
            "data":{"pc":"pub","sdp":"v=0 answer"}}
            """)
        }
        _ = try? await firstPublish
        _ = try? await secondPublish
        try await settle(4)
    }

    /*
     静默失败审计 §A：这张回滚表原先不认 `room.publish` / `room.subscribe`。发布被拒之后那条轨道
     永远停在 `publishing`——`publish.ok` 不来、pub offer 永不产出。界面显示已接通、计时器在走，
     对方全程听不见看不见，零提示。2026-09-16 拍板：**通话里被拒就结束本端通话**（reason=error）；
     没有通话的会议房只回滚那一条。
     */

    /// 通话中 `room.publish` 被拒：原错误码 throw 给调用方（不再发 onError），发 `call.hangup`，只抛一次 `onCallEnd{error}`。
    func testPublishRejectedDuringCallEndsTheCallWithErrorReason() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        ws.receive("""
        {"type":"call.incoming","req_id":"","ts":1,"data":{\
        "call_id":"c-1","room_id":"r-1","caller":"bob","callee_ids":["alice"],\
        "media_type":"audio","is_group":false,"timeout_sec":30,"invited_at_ms":1,"user_data":""}}
        """)
        try await settle(4)

        async let accepting: Void = h.engine.accept()
        let accept = try await waitForFrame(ws, ofType: IMFrameType.callAccept)
        ws.receive("""
        {"type":"call.accept.ok","req_id":"\(accept.reqID)","ts":1,"data":{}}
        """)
        try await accepting
        ws.receive("""
        {"type":"call.connected","req_id":"","ts":1,"data":{\
        "call_id":"c-1","room_id":"r-1","room_token":"rt-1","media_type":"audio",\
        "is_group":false,"connected_at_ms":1,"accepted_by":"alice"}}
        """)
        let join = try await waitForFrame(ws, ofType: IMFrameType.roomJoin)
        ws.receive("""
        {"type":"room.join.ok","req_id":"\(join.reqID)","ts":1,"data":{\
        "room_id":"r-1","participant_id":"r-1-p1","participants":[],"tracks":[]}}
        """)
        try await settle(4)
        let joined = await h.engine.state
        XCTAssertEqual(joined.room.state, .joined, "先把房间接通，发布被拒才有意义")

        let publishingEngine = h.engine
        let publishing = Task { try await publishingEngine.publishMicrophone() }
        let publish = try await waitForFrame(ws, ofType: IMFrameType.roomPublish)
        ws.receive("""
        {"type":"sys.error","req_id":"\(publish.reqID)","ts":1,\
        "data":{"code":1302,"name":"publish_denied","msg":"publish denied",\
        "for_type":"room.publish","retryable":false}}
        """)
        await assertThrowsCode(.publishDenied, forType: IMFrameType.roomPublish) { _ = try await publishing.value }
        let hangup = try await waitForFrame(ws, ofType: IMFrameType.callHangup)
        XCTAssertEqual(hangup.data["call_id"]?.stringValue, "c-1", "对端还在等，要告诉服务端我走了")
        try await settle(6)

        XCTAssertEqual(h.events.count(.error), 0, "原错误码已经交给调用方，不再发 onError")
        XCTAssertEqual(h.events.count(.callEnd), 1, "不能留在一通对方听不见的通话里")
        XCTAssertEqual(h.events.first(.callEnd)?.payload["reason"] as? String, "error",
                       "这不是用户按的红键，写成 hangup/cancel/reject 都是撒谎")

        let ended = await h.engine.state
        XCTAssertEqual(ended.call.state, .idle)
        XCTAssertEqual(ended.room.state, .idle)

        // 服务端随后那条 call.ended 不能再抛第二次。
        ws.receive("""
        {"type":"call.ended","req_id":"","ts":1,"data":{"call_id":"c-1","room_id":"r-1",\
        "reason":"hangup","duration_sec":3,"ended_by":"alice"}}
        """)
        try await settle()
        XCTAssertEqual(h.events.count(.callEnd), 1)
    }

    /// 会议房（没有通话）`room.publish` 被拒：只摘掉那条 `publishing`，人留在房里，之后还能再发布。
    func testPublishRejectedInMeetingOnlyDropsThatTrack() async throws {
        let h = makeEngine()
        let ws = try await login(h)
        try await joinRoom(h, ws)

        let publishingEngine = h.engine
        let publishing = Task { try await publishingEngine.publishCamera() }
        let publish = try await waitForFrame(ws, ofType: IMFrameType.roomPublish)
        XCTAssertEqual(publish.data["cid"]?.stringValue, "cam-1")
        ws.receive("""
        {"type":"sys.error","req_id":"\(publish.reqID)","ts":1,\
        "data":{"code":1302,"name":"publish_denied","msg":"publish denied",\
        "for_type":"room.publish","retryable":false}}
        """)
        await assertThrowsCode(.publishDenied, forType: IMFrameType.roomPublish) { _ = try await publishing.value }
        try await settle(6)

        let state = await h.engine.state
        XCTAssertEqual(state.room.state, .joined, "没有通话，收场动作止步于摘记账，不离房")
        XCTAssertNil(state.room.publish["cam-1"], "不能永远停在 publishing")
        XCTAssertEqual(h.events.count(.roomLeft), 0)
        XCTAssertEqual(h.events.count(.callEnd), 0)
        XCTAssertEqual(h.events.count(.error), 0, "错误只从 throw 出去")

        // 摘掉之后必须能重新发布，不能被判重卡住——走完整条正常路径直到 pub answer 落地。
        async let retrying = h.engine.publishCamera()
        let republish = try await waitForFrame(ws, ofType: IMFrameType.roomPublish,
                                               excludingReqID: publish.reqID)
        XCTAssertEqual(republish.data["cid"]?.stringValue, "cam-1")
        ws.receive("""
        {"type":"room.publish.ok","req_id":"\(republish.reqID)","ts":1,\
        "data":{"cid":"cam-1","track_id":"t-9"}}
        """)
        _ = try await retrying
        let offer = try await waitForFrame(ws, ofType: IMFrameType.roomOffer)
        ws.receive("""
        {"type":"room.answer","req_id":"\(offer.reqID)","ts":1,\
        "data":{"pc":"pub","sdp":"v=0 answer"}}
        """)
        try await settle(4)
    }

    private func joinRoom(_ h: Harness, _ ws: FakeWebSocket) async throws {
        async let joining: Void = h.engine.joinRoom("r-1", roomToken: "rt-1")
        let join = try await waitForFrame(ws, ofType: IMFrameType.roomJoin)
        ws.receive("""
        {"type":"room.join.ok","req_id":"\(join.reqID)","ts":1,"data":{\
        "room_id":"r-1","participant_id":"r-1-p1","participants":[],"tracks":[]}}
        """)
        try await joining
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

    /// 同上，但排除一个已知的旧 `req_id`——判重之类的场景里，「这一类帧已经出现过」
    /// 不代表「新的那一帧已经出现过」，`.last(where:)` 光看类型会立刻命中那条旧的。
    private func waitForFrame(_ ws: FakeWebSocket, ofType type: String,
                              excludingReqID: String) async throws -> IMEnvelope {
        for _ in 0..<400 {
            if let match = ws.frames().last(where: { $0.type == type && $0.reqID != excludingReqID }) {
                return match
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到帧 \(type)（排除 \(excludingReqID)）")
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
            "auto_subscribe": .string("all"),
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
            "auto_subscribe": .string("all"),
        ])).state
        ctx = IMEngineMachine.reduce(ctx, .internalEvent(name: "join_failed")).state

        let again = IMEngineMachine.reduce(ctx, .act(op: "join", args: [
            "room_id": .string("r-2"), "room_token": .string("rt2"),
            "auto_subscribe": .string("all"),
        ]))
        XCTAssertEqual(again.state.room.state, .joining)
        XCTAssertEqual(again.send.map(\.type), [IMFrameType.roomJoin])
    }
}
