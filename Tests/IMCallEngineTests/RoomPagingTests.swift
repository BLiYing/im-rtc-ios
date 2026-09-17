import XCTest
@testable import IMCallEngine

/**
 会议房按页订阅（`MEETING_ROOM_DESIGN.md` §4.3）。

 一致性向量（`room_fsm.json` 的 `meeting_audio_auto_video_by_page` 与
 `call_room_auto_subscribe_all_layer_only`）钉的是**正常翻页那一条线**，
 这里补的是向量表达不了的两件事：**16 路上限**与**翻回来撤掉迟滞**。
 */
final class RoomPagingTests: XCTestCase {
    private func meetingContext(videoCount: Int) -> IMRoomContext {
        var ctx = IMRoomContext()
        ctx.state = .joined
        ctx.roomID = "r-m"
        ctx.didJoin = true
        ctx.autoSubscribe = "audio"
        for i in 1...videoCount {
            ctx.remoteTracks["t-\(i)"] = IMRemoteTrack(uid: "u\(i)", kind: "video",
                                                       participantID: "p-\(i)")
        }
        return ctx
    }

    private func layer(_ ctx: IMRoomContext, _ trackID: String,
                       _ maxLayer: String) -> IMMachineOutput<IMRoomContext> {
        IMRoomMachine.reduce(ctx, .act(op: "update_layer", args: [
            "track_id": .string(trackID), "max_layer": .string(maxLayer),
        ]))
    }

    /// subscribeAll 把前 count 条视频都订上并坐实（模拟一页一页翻过来）。
    private func subscribeAll(_ start: IMRoomContext, _ count: Int) -> IMRoomContext {
        var ctx = start
        for i in 1...count { ctx = layer(ctx, "t-\(i)", "l").state }
        for key in ctx.subscribe.keys { ctx.subscribe[key] = .subscribed }
        return ctx
    }

    // MARK: - 会议房

    func testPageOutStopsPacketsThenUnsubscribesAfterHysteresis() {
        let ctx = subscribeAll(meetingContext(videoCount: 3), 1)

        let out = layer(ctx, "t-1", "none")
        XCTAssertEqual(out.send.map(\.type), [IMFrameType.roomUpdateLayer],
                       "这一步只停包，不退订")
        XCTAssertEqual(out.state.pendingUnsubscribe, ["t-1"])
        XCTAssertEqual(out.state.subscribe["t-1"], .subscribed, "订阅关系还在")

        let elapsed = IMRoomMachine.reduce(out.state, .internalEvent(
            name: "unsubscribe_hysteresis_elapsed", args: ["track_id": .string("t-1")]))
        XCTAssertEqual(elapsed.send.map(\.type), [IMFrameType.roomUnsubscribe])
        XCTAssertEqual(elapsed.state.subscribe["t-1"], .unsubscribing)
        XCTAssertTrue(elapsed.state.pendingUnsubscribe.isEmpty)
    }

    func testPageBackWithinHysteresisOnlyChangesLayer() {
        let ctx = subscribeAll(meetingContext(videoCount: 3), 1)
        let out = layer(layer(ctx, "t-1", "none").state, "t-1", "l")

        XCTAssertEqual(out.send.map(\.type), [IMFrameType.roomUpdateLayer],
                       "翻回来不该再订一次——那就是一次白白的重协商")
        XCTAssertTrue(out.state.pendingUnsubscribe.isEmpty, "计时要撤掉")
        XCTAssertEqual(out.state.subscribe["t-1"], .subscribed)

        // 计时撤掉之后，那条内部事件迟到了也不许退订。
        let late = IMRoomMachine.reduce(out.state,
                                        .internalEvent(name: "unsubscribe_hysteresis_elapsed"))
        XCTAssertTrue(late.send.isEmpty)
        XCTAssertEqual(late.state.subscribe["t-1"], .subscribed)
    }

    func testRepeatedNoneDoesNotResendOrExtendTheTimer() {
        let ctx = subscribeAll(meetingContext(videoCount: 3), 1)
        let twice = layer(layer(ctx, "t-1", "none").state, "t-1", "none")
        XCTAssertTrue(twice.send.isEmpty)
        XCTAssertEqual(twice.state.pendingUnsubscribe, ["t-1"])
    }

    func testNoneOnANeverSubscribedTrackSendsNothing() {
        let out = layer(meetingContext(videoCount: 3), "t-2", "none")
        XCTAssertTrue(out.send.isEmpty)
        XCTAssertTrue(out.state.pendingUnsubscribe.isEmpty)
    }

    func testFullQuotaFreesTheOldestPagedOutTrack() {
        let maxVideo = IMRoomMachine.maxSubscribedVideo
        var ctx = subscribeAll(meetingContext(videoCount: maxVideo + 1), maxVideo)
        // 翻走两条（t-1 比 t-2 早），它们都还在五秒迟滞里占着 m-line。
        ctx = layer(ctx, "t-1", "none").state
        ctx = layer(ctx, "t-2", "none").state
        XCTAssertEqual(ctx.pendingUnsubscribe, ["t-1", "t-2"])

        let out = layer(ctx, "t-\(maxVideo + 1)", "l")
        XCTAssertEqual(out.send.map(\.type),
                       [IMFrameType.roomUnsubscribe, IMFrameType.roomSubscribe],
                       "先退最早翻走的那一条，再订新的")
        XCTAssertEqual(out.send.first?.data["track_id"]?.stringValue, "t-1")
        XCTAssertEqual(out.state.pendingUnsubscribe, ["t-2"], "t-2 还在迟滞里，没被牵连")
        XCTAssertNil(out.reject)
    }

    func testNothingToFreeIsRejectedLocallyRatherThanQueued() {
        // 16 路全订着且一条都没翻走：这只可能是界面一次要看超过 16 路。
        let maxVideo = IMRoomMachine.maxSubscribedVideo
        let ctx = subscribeAll(meetingContext(videoCount: maxVideo + 1), maxVideo)
        let out = layer(ctx, "t-\(maxVideo + 1)", "l")

        XCTAssertTrue(out.send.isEmpty, "本地拒绝不许带帧")
        XCTAssertEqual(out.reject, .invalidState)
        XCTAssertNil(out.state.subscribe["t-\(maxVideo + 1)"])
    }

    func testParticipantLeftDropsPendingUnsubscribe() {
        let ctx = layer(subscribeAll(meetingContext(videoCount: 3), 1), "t-1", "none").state
        let left = IMRoomMachine.reduce(ctx, .recv(type: IMFrameType.roomParticipantLeft, data: [
            "room_id": .string("r-m"), "participant_id": .string("p-1"),
            "uid": .string("u1"), "device_id": .string("d1"),
        ]))
        XCTAssertTrue(left.state.pendingUnsubscribe.isEmpty)
        XCTAssertNil(left.state.subscribe["t-1"])
    }

    // MARK: - 通话房的护栏

    private func callContext() -> IMRoomContext {
        var ctx = IMRoomContext()
        ctx.state = .joined
        ctx.roomID = "r-c"
        ctx.didJoin = true
        ctx.autoSubscribe = "all"
        ctx.remoteTracks["t-1"] = IMRemoteTrack(uid: "bob", kind: "video", participantID: "p-1")
        ctx.subscribe["t-1"] = .subscribed
        return ctx
    }

    func testCallRoomNoneOnlyChangesLayer() {
        let out = layer(callContext(), "t-1", "none")
        XCTAssertEqual(out.send.map(\.type), [IMFrameType.roomUpdateLayer])
        XCTAssertTrue(out.state.pendingUnsubscribe.isEmpty)
        XCTAssertEqual(out.state.subscribe["t-1"], .subscribed,
                       "通话房退订会让那个人的画面再也回不来")
    }

    func testCallRoomIgnoresHysteresisEvent() {
        let out = IMRoomMachine.reduce(callContext(),
                                       .internalEvent(name: "unsubscribe_hysteresis_elapsed"))
        XCTAssertTrue(out.send.isEmpty)
        XCTAssertEqual(out.state.subscribe["t-1"], .subscribed)
    }

    func testUnknownAutoSubscribeFallsBackToAllNotNone() {
        let out = IMRoomMachine.reduce(IMRoomContext(), .act(op: "join", args: [
            "room_id": .string("r-1"), "room_token": .string("tk"),
            "auto_subscribe": .string("video"),
        ]))
        XCTAssertEqual(out.state.autoSubscribe, "all")
        XCTAssertEqual(out.send.first?.data["auto_subscribe"]?.stringValue, "all")
    }

    func testAudioModeAutoSubscribesAudioOnly() {
        var ctx = IMRoomContext()
        ctx.state = .joining
        ctx.autoSubscribe = "audio"
        let joined = IMRoomMachine.reduce(ctx, .recv(type: "room.join.ok", data: [
            "room_id": .string("r-m"),
            "room_kind": .string("meeting"),
            "participant_id": .string("p-9"),
            "participants": .array([]),
            "tracks": .array([
                .object(["track_id": .string("t-a1"), "participant_id": .string("p-1"),
                         "uid": .string("bob"), "kind": .string("audio"),
                         "source": .string("microphone"), "codec": .string("opus"),
                         "simulcast_layers": .array([]), "muted": .bool(false)]),
                .object(["track_id": .string("t-v1"), "participant_id": .string("p-1"),
                         "uid": .string("bob"), "kind": .string("video"),
                         "source": .string("camera"), "codec": .string("vp8"),
                         "simulcast_layers": .array([.string("l")]), "muted": .bool(false)]),
            ]),
        ]))
        XCTAssertEqual(joined.state.subscribe["t-a1"], .subscribing, "音频由服务端自动订上")
        XCTAssertNil(joined.state.subscribe["t-v1"], "视频要等界面报「看得见」才订")
    }
}
