import XCTest
@testable import IMCallEngine

/*
 「请求被服务端拒了之后能不能收场」——2026-09-08 那轮 code review 的三条回归。

 这三条的共同点是**症状完全一样、也完全看不出来**：状态机停在一个中间态，
 界面收不起来，而那个状态下红按钮算出的动作又会被本地拒成 2005。
 日志里只有一串一模一样的 2005，真正的原因（某一帧被拒了）淹在上一条 error 里。

 三条都是 Android 早就有、iOS 漏掉的分支，所以断言写成「与 Android 同一个收场」。
*/
final class RequestFailureRecoveryTests: XCTestCase {

    // MARK: - leave_failed：离房被拒也要回 idle

    /// `room.leave` 被拒（1203 会话已不在房间里）**必须与 leave.ok 同一个收场**。
    ///
    /// 不接这一条的话房间永久停在 leaving：`onRoomLeft` 不抛 → 门面的 leaveCallbacks
    /// 一个都不触发 → `media.close()` 永远不调用（摄像头麦克风一直开着），
    /// 再 leave 被 R1 拒成 2005，再 join 因为「不在 idle」也被拒。
    func testLeaveFailedReturnsToIdleAndEmitsRoomLeft() {
        var ctx = joinedRoom()
        ctx = IMRoomMachine.reduce(ctx, .act(op: "leave")).state
        XCTAssertEqual(ctx.state, .leaving, "leave 之后应该在 leaving")

        let result = IMRoomMachine.reduce(ctx, .internalEvent(name: "leave_failed"))

        XCTAssertEqual(result.state.state, .idle, "离房被拒之后必须回 idle")
        XCTAssertEqual(result.emit.map(\.callback), ["onRoomLeft"],
                       "界面需要一个明确的收场信号，房间的收场信号就是 onRoomLeft")
        XCTAssertTrue(result.send.isEmpty, "被拒之后不该再往一个我们已经不在的房间发帧")
    }

    /// 归零要归干净：残留的发布/订阅记账会在下一次进房时被当成「上一轮还没收工」。
    func testLeaveFailedClearsBookkeeping() {
        var ctx = joinedRoom()
        ctx.publish["cam-1"] = .published
        ctx.subscribe["t-9"] = .subscribed
        ctx = IMRoomMachine.reduce(ctx, .act(op: "leave")).state

        let after = IMRoomMachine.reduce(ctx, .internalEvent(name: "leave_failed")).state

        XCTAssertTrue(after.publish.isEmpty, "离房之后不该留着发布记账")
        XCTAssertTrue(after.subscribe.isEmpty, "离房之后不该留着订阅记账")
    }

    /// **只在 leaving 时才认**：别的状态下收到它是本端自己的实现错，不该顺手把房间清掉。
    func testLeaveFailedIsIgnoredOutsideLeaving() {
        let joined = joinedRoom()
        let result = IMRoomMachine.reduce(joined, .internalEvent(name: "leave_failed"))
        XCTAssertEqual(result.state.state, .joined, "不在 leaving 时 leave_failed 应当是空操作")
        XCTAssertTrue(result.emit.isEmpty)
    }

    /// leave_failed 要能从 engine 层路由到房间机——漏了这一跳就会被当成通话机的内部事件吞掉。
    func testEngineRoutesLeaveFailedToRoomMachine() {
        var ctx = IMEngineContext()
        ctx.room = joinedRoom()
        ctx.room = IMRoomMachine.reduce(ctx.room, .act(op: "leave")).state

        let result = IMEngineMachine.reduce(ctx, .internalEvent(name: "leave_failed"))

        XCTAssertEqual(result.state.room.state, .idle)
        XCTAssertEqual(result.emit.map(\.callback), ["onRoomLeft"])
    }

    // MARK: - publish_failed / subscribe_failed：静默失败审计 §A

    /*
     这张回滚表原先也不认 `room.publish` / `room.subscribe`。发布被拒的收场在通话里走
     forceEnd（见 `FacadeTests` 的门面级用例），这里只覆盖**没有通话的会议房**：
     状态机只摘掉那一条记账，不额外抛回调、不离房。
     */

    /// 会议房 `room.publish` 被拒：只摘掉那一条 `publishing`，其余记账不动，人还在 joined。
    func testPublishFailedDropsOnlyThatPublishingEntry() {
        var ctx = joinedRoom()
        ctx.publish["cam-1"] = .publishing
        ctx.publish["mic-1"] = .published

        let result = IMRoomMachine.reduce(ctx, .internalEvent(name: "publish_failed",
                                                               args: ["cid": .string("cam-1")]))

        XCTAssertEqual(result.state.state, .joined, "没有通话，收场只到摘记账为止，不离房")
        XCTAssertNil(result.state.publish["cam-1"], "不能永远停在 publishing")
        XCTAssertEqual(result.state.publish["mic-1"], .published, "已经发布成功的那条不该被碰")
        XCTAssertTrue(result.emit.isEmpty, "错误已经由帧循环抛过一次，这里不重复抛")
        XCTAssertTrue(result.send.isEmpty)
    }

    /// **只认 `publishing`**：不是那个状态时收到（比如已经 published 之后才迟到的失败回执）
    /// 是空操作，不能把一条已经成功的发布顺手摘掉。
    func testPublishFailedIsIgnoredWhenNotPublishing() {
        var ctx = joinedRoom()
        ctx.publish["mic-1"] = .published

        let result = IMRoomMachine.reduce(ctx, .internalEvent(name: "publish_failed",
                                                               args: ["cid": .string("mic-1")]))

        XCTAssertEqual(result.state.publish["mic-1"], .published)
    }

    /// `room.subscribe` 被拒：摘掉 `subscribing` **连同层记账**，重订之后重新发 `room.subscribe`。
    ///
    /// 层记账不摘的话不变量 R3 会把重订当成换层，只发 `room.update_layer`，
    /// 状态机就再也发不出 `room.subscribe` 了。
    func testSubscribeFailedDropsBookkeepingAndAllowsResubscribe() {
        var ctx = joinedRoom()
        let subscribing = IMRoomMachine.reduce(ctx, .act(op: "subscribe", args: [
            "track_id": .string("t-9"), "max_layer": .string("h"),
        ]))
        ctx = subscribing.state
        XCTAssertEqual(ctx.subscribe["t-9"], .subscribing)
        XCTAssertEqual(ctx.layers["t-9"], "h")

        let rolled = IMRoomMachine.reduce(ctx, .internalEvent(name: "subscribe_failed",
                                                               args: ["track_id": .string("t-9")]))
        XCTAssertNil(rolled.state.subscribe["t-9"])
        XCTAssertNil(rolled.state.layers["t-9"], "层记账也要摘，否则 R3 会把重订误判成换层")
        XCTAssertTrue(rolled.emit.isEmpty)

        let again = IMRoomMachine.reduce(rolled.state, .act(op: "subscribe", args: [
            "track_id": .string("t-9"), "max_layer": .string("h"),
        ]))
        XCTAssertEqual(again.send.map(\.type), [IMFrameType.roomSubscribe],
                       "摘账之后重订必须真的再发一次 room.subscribe，不能被 R3 当成换层")
    }

    /// 已经 `subscribed` 的那条不受影响——只动 `subscribing` 那一条。
    func testSubscribeFailedIsIgnoredWhenNotSubscribing() {
        var ctx = joinedRoom()
        ctx.subscribe["t-1"] = .subscribed
        ctx.layers["t-1"] = "m"

        let result = IMRoomMachine.reduce(ctx, .internalEvent(name: "subscribe_failed",
                                                               args: ["track_id": .string("t-1")]))

        XCTAssertEqual(result.state.subscribe["t-1"], .subscribed)
        XCTAssertEqual(result.state.layers["t-1"], "m")
    }

    /// publish_failed / subscribe_failed 要能从 engine 层路由到房间机——
    /// 漏了这一跳就会被当成通话机的内部事件吞掉（Web 端曾经的坑，见 `ROOM_FAILURES`）。
    func testEngineRoutesPublishAndSubscribeFailedToRoomMachine() {
        var ctx = IMEngineContext()
        ctx.room = joinedRoom()
        ctx.room.publish["cam-1"] = .publishing
        ctx.room.subscribe["t-1"] = .subscribing

        let afterPublish = IMEngineMachine.reduce(ctx, .internalEvent(name: "publish_failed",
                                                                       args: ["cid": .string("cam-1")]))
        XCTAssertNil(afterPublish.state.room.publish["cam-1"])
        XCTAssertEqual(afterPublish.state.room.state, .joined, "不该被误路由到通话机导致状态跑偏")

        let afterSubscribe = IMEngineMachine.reduce(afterPublish.state,
                                                     .internalEvent(name: "subscribe_failed",
                                                                    args: ["track_id": .string("t-1")]))
        XCTAssertNil(afterSubscribe.state.room.subscribe["t-1"])
    }

    // MARK: - call_failed：accept / join 被拒也要回 idle

    /// `call.accept` 被拒（主叫刚取消，服务端回 1401）**必须抛 onCallEnd 并回 idle**。
    ///
    /// 不接的话通话机永久停在 accepting：来电页收不起来，而那时红按钮算出来的是
    /// reject，`reduceAct("reject")` 又要求 ringing——只换回又一个 2005，
    /// 用户除了杀进程出不去。
    func testCallFailedFromAcceptingEndsTheCall() {
        var ctx = IMCallContext()
        ctx.state = .ringing
        ctx.callID = "call-1"
        ctx = IMCallMachine.reduce(ctx, .act(op: "accept")).state
        XCTAssertEqual(ctx.state, .accepting, "accept 之后应该在 accepting")

        let result = IMCallMachine.reduce(ctx, .internalEvent(name: "call_failed"))

        XCTAssertEqual(result.state.state, .idle, "接听被拒之后必须回 idle")
        XCTAssertEqual(result.emit.map(\.callback), ["onCallEnd"],
                       "onCallEnd 是所有结束分支的唯一出口（设计 §7.5）")
        XCTAssertEqual(result.emit.first?.args["reason"]?.stringValue,
                       IMCallEndReason.error.wireValue,
                       "这通电话从未建立，hangup/cancel/reject 哪个都不是实情")
    }

    /// `call.join`（主动加入进行中的群通话）被拒同理——它也停在 accepting。
    func testCallFailedFromJoinCallEndsTheCall() {
        var ctx = IMCallContext()
        ctx = IMCallMachine.reduce(ctx, .act(op: "join_call",
                                             args: ["call_id": .string("call-9")])).state
        XCTAssertEqual(ctx.state, .accepting)

        let result = IMCallMachine.reduce(ctx, .internalEvent(name: "call_failed"))

        XCTAssertEqual(result.state.state, .idle)
        XCTAssertEqual(result.emit.map(\.callback), ["onCallEnd"])
    }

    /// 通话结束时房间也要跟着归零——这条是 `liftCall` 管的，别在补分支时把它弄丢。
    func testCallFailedAlsoClearsTheRoom() {
        var ctx = IMEngineContext()
        ctx.call.state = .accepting
        ctx.call.callID = "call-1"
        ctx.room = joinedRoom()

        let result = IMEngineMachine.reduce(ctx, .internalEvent(name: "call_failed"))

        XCTAssertEqual(result.state.call.state, .idle)
        XCTAssertEqual(result.state.room.state, .idle, "通话结束 = 房间没了（§4.4）")
    }

    // MARK: - 辅助

    // MARK: - publish_deferred：没等到应答的发布挂起等重连（2026-09-18）

    /*
     `publish_failed`（服务端真回了拒绝）与 `publish_deferred`（压根没等到应答）
     必须分开。原先只有前者，于是请求超时也被当成「被拒」，通话里直接收成
     `reason=error`——真机 18:18:39 就这么丢了一通本来能接着打的电话，
     而 9 秒后连接就回来、会话也在恢复窗口内 resume 成功了。
    */

    /// 超时的发布：摘掉 `publishing`，但**意图要留着**，等回到 joined 再走一遍。
    func testPublishDeferredKeepsIntentForReplay() {
        var ctx = joinedRoom()
        ctx.publish["mic-1"] = .publishing

        let result = IMRoomMachine.reduce(ctx, .internalEvent(name: "publish_deferred", args: [
            "cid": .string("mic-1"), "kind": .string("audio"),
            "source": .string("microphone"), "simulcast": .bool(false),
        ]))

        XCTAssertNil(result.state.publish["mic-1"], "不能永远停在 publishing")
        XCTAssertEqual(result.state.buffered.count, 1, "意图要留着，否则这一路永远补不回来")
        XCTAssertEqual(result.state.buffered.first?.op, "publish")
        XCTAssertTrue(result.send.isEmpty, "此刻连接本来就不通，不该再发帧")
    }

    /// 挂起的发布要在**会话恢复之后**自己走回线路上——这才是与 `publish_failed` 的真正分别。
    func testDeferredPublishIsReplayedAfterResume() {
        var ctx = joinedRoom()
        ctx.publish["mic-1"] = .publishing
        ctx = IMRoomMachine.reduce(ctx, .internalEvent(name: "publish_deferred", args: [
            "cid": .string("mic-1"), "kind": .string("audio"),
            "source": .string("microphone"), "simulcast": .bool(false),
        ])).state
        ctx = IMRoomMachine.reduce(ctx, .internalEvent(name: "disconnected")).state
        XCTAssertEqual(ctx.state, .reconnecting)

        let resumed = IMRoomMachine.resume(ctx, resumed: true)

        XCTAssertEqual(resumed.state.state, .joined)
        XCTAssertEqual(resumed.send.map(\.type), [IMFrameType.roomPublish],
                       "恢复之后这一路要自己补发出去，不能等用户再点一次")
        XCTAssertEqual(resumed.send.first?.data["cid"]?.stringValue, "mic-1")
        XCTAssertEqual(resumed.state.publish["mic-1"], .publishing, "补发之后重新回到 publishing")
        XCTAssertTrue(resumed.state.buffered.isEmpty, "重放过就要清掉，否则下次恢复会再发一遍")
    }

    /// **只认 `publishing`**：迟到的超时不能把一条已经成功的发布摘掉、还排进重放队列。
    func testPublishDeferredIsIgnoredWhenNotPublishing() {
        var ctx = joinedRoom()
        ctx.publish["mic-1"] = .published

        let result = IMRoomMachine.reduce(ctx, .internalEvent(name: "publish_deferred",
                                                              args: ["cid": .string("mic-1")]))

        XCTAssertEqual(result.state.publish["mic-1"], .published)
        XCTAssertTrue(result.state.buffered.isEmpty)
    }

    private func joinedRoom() -> IMRoomContext {
        var ctx = IMRoomContext()
        ctx.state = .joined
        ctx.didJoin = true
        ctx.roomID = "r-1"
        ctx.roomToken = "rt-1"
        return ctx
    }
}
