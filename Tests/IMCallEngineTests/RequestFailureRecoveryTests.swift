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

    private func joinedRoom() -> IMRoomContext {
        var ctx = IMRoomContext()
        ctx.state = .joined
        ctx.didJoin = true
        ctx.roomID = "r-1"
        ctx.roomToken = "rt-1"
        return ctx
    }
}
