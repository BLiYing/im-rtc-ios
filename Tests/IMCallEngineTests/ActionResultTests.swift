import XCTest
@testable import IMCallEngine

/**
 **调用结果回给调用方**（server `docs/design/ACTION_RESULT_DESIGN.md`，2.0.0）。

 每个发起类方法四格：成功返回 / 本地拒绝 throw 2005 / 服务端拒绝 throw 那个码 / 等应答时断线 throw 2003；
 每格都断言**没有**多发 `onError`（R3：一次失败只从一个出口报）。
 连锁帧（R2）、退出类本地收场（D2）、提示与清理类不 throw（D3）各有单独的用例。
 Web 端同一份表：`packages/call-engine/test/actionResult.test.ts`。
 */
final class ActionResultTests: XCTestCase {

    // MARK: - 装配

    /// 只够发布用的假媒体：发布要先拿轨道，其余一律空操作。
    final class StubMedia: IMMediaAdapter, @unchecked Sendable {
        func open(_ events: IMMediaAdapterEvents) {}
        func acquireMicrophone() async throws -> IMLocalTrackInfo {
            IMLocalTrackInfo(cid: "mic-1", kind: "audio", source: "microphone")
        }
        func probeMicrophone() async throws {}
        func startLocalPreview() async throws -> IMLocalTrackInfo {
            IMLocalTrackInfo(cid: "cam-1", kind: "video", source: "camera")
        }
        func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo {
            IMLocalTrackInfo(cid: "cam-1", kind: "video", source: "camera")
        }
        func createPubOffer() async throws -> String { "v=0 offer" }
        func restartPubICE() {}
        func applyPubAnswer(_ sdp: String) async throws {}
        func answerSubOffer(_ sdp: String) async throws -> String { "v=0 answer" }
        func addRemoteCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async throws {}
        func setMuted(_ cid: String, _ muted: Bool) {}
        func setSpeakerOn(_ on: Bool) {}
        func switchCamera() async {}
        func claimRemoteTracks(_ owners: [String: String]) {}
        func attachRemoteView(_ uid: String, _ view: AnyObject?) {}
        func attachLocalView(_ cid: String, _ view: AnyObject?) {}
        func close() {}
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [IMCallEvent] = []
        func add(_ event: IMCallEvent) { lock.lock(); items.append(event); lock.unlock() }
        func named(_ name: IMCallEventName) -> [IMCallEvent] {
            lock.lock(); defer { lock.unlock() }; return items.filter { $0.name == name }
        }
        /// errors 是 onError 的 (码, for_type)。
        func errors() -> [(Int, String)] {
            named(.error).map { (($0.payload["code"] as? NSNumber)?.intValue ?? 0, $0.payload["for_type"] as? String ?? "") }
        }
    }

    struct Harness {
        let engine: IMCallEngine
        let ws: FakeWebSocket
        let events: Events
        /// box 拿的是**最近一条** socket：断线重连之后从这里取新的那条。
        let box: SocketBox
    }

    private func setup() async throws -> Harness {
        let box = SocketBox()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: StubMedia())
        engine.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        let events = Events()
        engine.addEventObserver { events.add($0) }
        async let done: Void = engine.login("token-1")
        var socket: FakeWebSocket?
        for _ in 0..<200 where socket == nil {
            socket = box.get()
            if socket == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        guard let ws = socket else { throw IMRTCError(.internalError, "没有建立连接") }
        ws.open()
        let hello = try await frame(ws, IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: hello.reqID))
        try await done
        try await settle()
        return Harness(engine: engine, ws: ws, events: events, box: box)
    }

    private func settle(_ rounds: Int = 6) async throws {
        for _ in 0..<rounds { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// frame 等某类帧出现，排除已经见过的 req_id。
    private func frame(_ ws: FakeWebSocket, _ type: String, excluding seen: Set<String> = []) async throws -> IMEnvelope {
        for _ in 0..<400 {
            if let match = ws.frames().last(where: { $0.type == type && !seen.contains($0.reqID) }) { return match }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到帧 \(type)")
    }

    private func reqIDs(_ ws: FakeWebSocket, _ type: String) -> Set<String> {
        Set(ws.frames().filter { $0.type == type }.map(\.reqID))
    }

    private func reply(_ ws: FakeWebSocket, _ req: IMEnvelope, _ type: String, _ data: String = "{}") {
        ws.receive(#"{"type":"\#(type)","req_id":"\#(req.reqID)","ts":1,"data":\#(data)}"#)
    }

    private func reject(_ ws: FakeWebSocket, _ req: IMEnvelope, _ code: IMErrorCode) {
        ws.receive(#"{"type":"sys.error","req_id":"\#(req.reqID)","ts":1,"data":{"code":\#(code.rawValue),"name":"\#(code.name)","msg":"x","for_type":"\#(req.type)","retryable":false}}"#)
    }

    private func event(_ ws: FakeWebSocket, _ type: String, _ data: String) {
        ws.receive(#"{"type":"\#(type)","req_id":"","ts":1,"data":\#(data)}"#)
    }

    // MARK: - 把 engine 推到某个状态

    private func idle(_ h: Harness) async throws {}

    private func ringing(_ h: Harness) async throws {
        event(h.ws, "call.incoming", #"{"call_id":"c-1","room_id":"r-1","caller":"bob","callee_ids":["alice"],"media_type":"audio","is_group":true,"timeout_sec":30,"invited_at_ms":1,"user_data":""}"#)
        try await settle(3)
    }

    private func inviting(_ h: Harness) async throws {
        async let calling: String = h.engine.call(["bob"], mediaType: "audio")
        let invite = try await frame(h.ws, IMFrameType.callInvite)
        reply(h.ws, invite, "call.invite.ok", #"{"call_id":"c-1","room_id":"r-1"}"#)
        _ = try await calling
    }

    private func inCall(_ h: Harness) async throws {
        try await ringing(h)
        async let accepting: Void = h.engine.accept()
        let accept = try await frame(h.ws, IMFrameType.callAccept)
        reply(h.ws, accept, "call.accept.ok")
        try await accepting
        event(h.ws, "call.connected", #"{"call_id":"c-1","room_id":"r-1","room_token":"rt-1","media_type":"audio","is_group":true,"connected_at_ms":1,"accepted_by":"alice"}"#)
        let join = try await frame(h.ws, IMFrameType.roomJoin)
        reply(h.ws, join, "room.join.ok", #"{"room_id":"r-1","participant_id":"p-1","participants":[],"tracks":[]}"#)
        try await settle(3)
    }

    private func inMeeting(_ h: Harness) async throws {
        async let joining: Void = h.engine.joinRoom("m-1", roomToken: "tk")
        let join = try await frame(h.ws, IMFrameType.roomJoin)
        reply(h.ws, join, "room.join.ok", #"{"room_id":"m-1","participant_id":"p-1","participants":[],"tracks":[]}"#)
        try await joining
        try await settle(3)
    }

    // MARK: - 四格表

    struct MethodCase {
        let name: String
        let ready: (ActionResultTests, Harness) async throws -> Void
        let wrongState: (ActionResultTests, Harness) async throws -> Void
        let invoke: (IMCallEngine) async throws -> String
        let frame: String
        let okData: String
    }

    private var methods: [MethodCase] {
        [
            MethodCase(name: "call", ready: { try await $0.idle($1) }, wrongState: { try await $0.ringing($1) },
                       invoke: { try await $0.call(["bob"], mediaType: "audio") },
                       frame: IMFrameType.callInvite, okData: #"{"call_id":"c-9","room_id":"r-9"}"#),
            MethodCase(name: "joinCall", ready: { try await $0.idle($1) }, wrongState: { try await $0.ringing($1) },
                       invoke: { try await $0.joinCall("c-9"); return "" }, frame: IMFrameType.callJoin, okData: "{}"),
            MethodCase(name: "accept", ready: { try await $0.ringing($1) }, wrongState: { try await $0.idle($1) },
                       invoke: { try await $0.accept(); return "" }, frame: IMFrameType.callAccept, okData: "{}"),
            MethodCase(name: "reject", ready: { try await $0.ringing($1) }, wrongState: { try await $0.idle($1) },
                       invoke: { try await $0.reject(); return "" }, frame: IMFrameType.callReject, okData: "{}"),
            MethodCase(name: "cancel", ready: { try await $0.inviting($1) }, wrongState: { try await $0.idle($1) },
                       invoke: { try await $0.cancel(); return "" }, frame: IMFrameType.callCancel, okData: "{}"),
            MethodCase(name: "hangup", ready: { try await $0.inCall($1) }, wrongState: { try await $0.idle($1) },
                       invoke: { try await $0.hangup(); return "" }, frame: IMFrameType.callHangup, okData: "{}"),
            MethodCase(name: "inviteMore", ready: { try await $0.inCall($1) }, wrongState: { try await $0.idle($1) },
                       invoke: { try await $0.inviteMore(["carol"]); return "" }, frame: IMFrameType.callInviteMore, okData: "{}"),
            MethodCase(name: "joinRoom", ready: { try await $0.idle($1) }, wrongState: { try await $0.inMeeting($1) },
                       invoke: { try await $0.joinRoom("m-2", roomToken: "tk"); return "" }, frame: IMFrameType.roomJoin,
                       okData: #"{"room_id":"m-2","participant_id":"p-2","participants":[],"tracks":[]}"#),
            MethodCase(name: "leaveRoom", ready: { try await $0.inMeeting($1) }, wrongState: { try await $0.idle($1) },
                       invoke: { try await $0.leaveRoom(); return "" }, frame: IMFrameType.roomLeave, okData: "{}"),
            MethodCase(name: "publishMicrophone", ready: { try await $0.inMeeting($1) }, wrongState: { try await $0.idle($1) },
                       invoke: { try await $0.publishMicrophone() }, frame: IMFrameType.roomPublish,
                       okData: #"{"cid":"mic-1","track_id":"t-1"}"#),
        ]
    }

    func testSuccessReturnsWhenTheDirectFrameIsAcknowledged() async throws {
        for m in methods {
            let h = try await setup()
            try await m.ready(self, h)
            let seen = reqIDs(h.ws, m.frame)
            let engine = h.engine
            let task = Task { try await m.invoke(engine) }
            let sent = try await frame(h.ws, m.frame, excluding: seen)
            reply(h.ws, sent, m.frame + ".ok", m.okData)
            let value = try await task.value
            if m.name == "call" { XCTAssertEqual(value, "c-9", "call 返回 callID") }
            XCTAssertTrue(h.events.errors().isEmpty, "\(m.name)：成功不该有 onError")
        }
    }

    func testLocalRejectThrows2005WithoutFramesOrOnError() async throws {
        for m in methods {
            let h = try await setup()
            try await m.wrongState(self, h)
            let before = reqIDs(h.ws, m.frame).count
            await assertThrowsCode(.invalidState) { _ = try await m.invoke(h.engine) }
            try await settle(2)
            XCTAssertEqual(reqIDs(h.ws, m.frame).count, before, "\(m.name)：本地拒绝不许发帧")
            XCTAssertTrue(h.events.errors().isEmpty, "\(m.name)：本地拒绝不再发 onError")
        }
    }

    func testServerRejectThrowsThatCodeWithForType() async throws {
        for m in methods {
            let h = try await setup()
            try await m.ready(self, h)
            let seen = reqIDs(h.ws, m.frame)
            let engine = h.engine
            let task = Task { try await m.invoke(engine) }
            let sent = try await frame(h.ws, m.frame, excluding: seen)
            reject(h.ws, sent, .roomNotFound)
            await assertThrowsCode(.roomNotFound, forType: m.frame) { _ = try await task.value }
            try await settle(3)
            XCTAssertTrue(h.events.errors().isEmpty, "\(m.name)：已经 throw 的错误不再发 onError")
        }
    }

    func testDisconnectWhileAwaitingReplyThrows2003() async throws {
        for m in methods {
            let h = try await setup()
            try await m.ready(self, h)
            let seen = reqIDs(h.ws, m.frame)
            let engine = h.engine
            let task = Task { try await m.invoke(engine) }
            _ = try await frame(h.ws, m.frame, excluding: seen)
            h.ws.closeFromServer(1006)
            await assertThrowsCode(.networkUnreachable, forType: m.frame) { _ = try await task.value }
            try await settle(3)
            XCTAssertTrue(h.events.errors().filter { $0.1 == m.frame }.isEmpty, "\(m.name)：不再发 onError")
            await h.engine.logout()
        }
    }

    /// 会议房（没有通话）里发布**没等到应答**，也要挂起等重连，而不是悄悄丢掉。
    ///
    /// 原先「挂起」那条只对通话开放（`ctx.call.state != .idle`），会议房落到 `publish_failed`：
    /// 这一路从记账里摘掉、不重试、不通知宿主——信令抖一下，用户就静音或黑屏，界面上什么也看不出。
    func testMeetingPublishInterruptedByDisconnectIsReplayedAfterResume() async throws {
        try await assertPublishReplayedAfterResume { try await self.inMeeting($0) }
    }

    /// 通话里同一件事。`bfbf7c9` 本意就是修它，但 `publish_deferred` 没登记进 `roomInternals`，
    /// 被路由到通话机静默丢掉——这一路永远停在 `publishing`，恢复之后也不补发。
    func testCallPublishInterruptedByDisconnectIsReplayedAfterResume() async throws {
        try await assertPublishReplayedAfterResume { try await self.inCall($0) }
    }

    private func assertPublishReplayedAfterResume(_ ready: (Harness) async throws -> Void) async throws {
        let h = try await setup()
        try await ready(h)
        let engine = h.engine
        let task = Task { try await engine.publishMicrophone() }
        _ = try await frame(h.ws, IMFrameType.roomPublish)
        h.ws.closeFromServer(IMCloseCode.goingAway)
        await assertThrowsCode(.networkUnreachable, forType: IMFrameType.roomPublish) { _ = try await task.value }

        var next: FakeWebSocket?
        for _ in 0..<600 where next == nil {
            if let s = h.box.get(), s !== h.ws { next = s } else { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        guard let ws = next else { return XCTFail("没有重连") }
        ws.open()
        let hello = try await frame(ws, IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: hello.reqID, resumed: true))

        let replayed = try await frame(ws, IMFrameType.roomPublish)
        XCTAssertEqual(replayed.data["cid"]?.stringValue, "mic-1", "恢复之后这一路要自己补发，不能被丢掉")
        await h.engine.logout()
    }

    // MARK: - 退出类失败：本地照样收场（D2）

    func testHangupRejectedStillEndsLocallyOnce() async throws {
        let h = try await setup()
        try await inCall(h)
        let engine = h.engine
        let hanging = Task { try await engine.hangup() }
        let hangup = try await frame(h.ws, IMFrameType.callHangup)
        reject(h.ws, hangup, .callEnded)
        await assertThrowsCode(.callEnded, forType: IMFrameType.callHangup) { try await hanging.value }
        try await settle(3)
        XCTAssertEqual(h.events.named(.callEnd).count, 1)
        XCTAssertEqual(h.events.named(.callEnd).first?.payload["reason"] as? String, "hangup")
        let state = await h.engine.state
        XCTAssertEqual(state.call.state, .idle)
        XCTAssertEqual(state.room.state, .idle)
        XCTAssertTrue(h.events.errors().isEmpty)

        event(h.ws, "call.ended", #"{"call_id":"c-1","room_id":"r-1","reason":"hangup","duration_sec":3,"ended_by":"alice"}"#)
        try await settle(3)
        XCTAssertEqual(h.events.named(.callEnd).count, 1, "服务端随后的 call.ended 不再抛第二次")
    }

    func testLeaveRoomDisconnectStillLeavesLocally() async throws {
        let h = try await setup()
        try await inMeeting(h)
        let engine = h.engine
        let leaving = Task { try await engine.leaveRoom() }
        _ = try await frame(h.ws, IMFrameType.roomLeave)
        h.ws.closeFromServer(1006)
        await assertThrowsCode(.networkUnreachable, forType: IMFrameType.roomLeave) { try await leaving.value }
        try await settle(3)
        XCTAssertEqual(h.events.named(.roomLeft).count, 1)
        let state = await h.engine.state
        XCTAssertEqual(state.room.state, .idle, "断线先进了 reconnecting，也要收场")
        await h.engine.logout()
    }

    // MARK: - 连锁帧失败找不到调用方（R2）

    func testChainedRoomJoinFailureGoesToOnErrorWithForType() async throws {
        let h = try await setup()
        try await ringing(h)
        async let accepting: Void = h.engine.accept()
        let accept = try await frame(h.ws, IMFrameType.callAccept)
        reply(h.ws, accept, "call.accept.ok")
        try await accepting
        event(h.ws, "call.connected", #"{"call_id":"c-1","room_id":"r-1","room_token":"rt-1","media_type":"audio","is_group":true,"connected_at_ms":1,"accepted_by":"alice"}"#)
        let join = try await frame(h.ws, IMFrameType.roomJoin)
        reject(h.ws, join, .roomNotFound)
        try await settle(4)
        let errors = h.events.errors()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.0, IMErrorCode.roomNotFound.rawValue)
        XCTAssertEqual(errors.first?.1, IMFrameType.roomJoin)
    }

    func testPublishWhileJoiningIsAcceptedAndReplayFailureGoesToOnError() async throws {
        let h = try await setup()
        async let joining: Void = h.engine.joinRoom("m-1", roomToken: "tk")
        let join = try await frame(h.ws, IMFrameType.roomJoin)
        let cid = try await h.engine.publishMicrophone()
        XCTAssertEqual(cid, "mic-1", "意图被缓存：调用已受理，立即返回")
        XCTAssertFalse(h.ws.frames().contains { $0.type == IMFrameType.roomPublish })

        reply(h.ws, join, "room.join.ok", #"{"room_id":"m-1","participant_id":"p-1","participants":[],"tracks":[]}"#)
        try await joining
        let publish = try await frame(h.ws, IMFrameType.roomPublish)
        reject(h.ws, publish, .publishDenied)
        try await settle(4)
        XCTAssertEqual(h.events.errors().first?.1, IMFrameType.roomPublish)
    }

    // MARK: - 提示类与清理类不 throw（D3）

    func testCloseMicrophoneMuteRejectedGoesToOnError() async throws {
        let h = try await setup()
        try await inMeeting(h)
        async let publishing: String = h.engine.publishMicrophone()
        let publish = try await frame(h.ws, IMFrameType.roomPublish)
        reply(h.ws, publish, "room.publish.ok", #"{"cid":"mic-1","track_id":"t-1"}"#)
        _ = try await publishing
        try await settle(3)

        async let closing: Void = h.engine.closeMicrophone()
        let mute = try await frame(h.ws, IMFrameType.roomMute)
        reject(h.ws, mute, .trackNotFound)
        await closing
        try await settle(2)
        XCTAssertEqual(h.events.errors().map(\.1), [IMFrameType.roomMute])
    }

    func testSetRemoteLayerRejectedGoesToOnError() async throws {
        let h = try await setup()
        async let joining: Void = h.engine.joinRoom("m-1", roomToken: "tk")
        let join = try await frame(h.ws, IMFrameType.roomJoin)
        reply(h.ws, join, "room.join.ok", #"{"room_id":"m-1","participant_id":"p-1","participants":[],"tracks":[{"track_id":"bob-cam","uid":"bob","kind":"video","source":"camera","simulcast":true,"muted":false}]}"#)
        try await joining
        try await settle(3)

        async let layering: Void = h.engine.setRemoteLayer("bob", layer: "l")
        let update = try await frame(h.ws, IMFrameType.roomUpdateLayer)
        reject(h.ws, update, .layerUnavailable)
        await layering
        try await settle(2)
        XCTAssertEqual(h.events.errors().map(\.0), [IMErrorCode.layerUnavailable.rawValue])
        XCTAssertEqual(h.events.errors().map(\.1), [IMFrameType.roomUpdateLayer])
    }
}
