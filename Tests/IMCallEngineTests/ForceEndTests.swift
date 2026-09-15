import XCTest
@testable import IMCallEngine

/**
 强制收场（`IMEngineMachine.forceEnd`）与「idle 下迟到的房间帧」。**纯函数，不需要网络。**

 守的是 2026-09-13 14:53~14:58 frank 那一场暴露出来的两件事：
 · 红键的结束帧没发出去时，界面收了而 Engine 还留在通话与房间里，别人一直看得见他；
 · 收场之后才回来的 `room.join.ok` 会把一个没人要的房间捡回来，或者让服务端一直挂着这个人。
 */
final class ForceEndTests: XCTestCase {

    private func inCall(_ state: IMCallState, callID: String = "c-1",
                        room: IMRoomState = .idle) -> IMEngineContext {
        var ctx = IMEngineContext()
        ctx.call.state = state
        ctx.call.callID = callID
        ctx.call.connectedAtMS = 1_000
        ctx.room.state = room
        ctx.room.roomID = room == .idle ? "" : "r-1"
        return ctx
    }

    // MARK: - 通话

    func testConnectedCallSendsHangupAndEndsLocally() {
        let out = IMEngineMachine.forceEnd(inCall(.connected, room: .joined), nowMS: 6_500)

        XCTAssertEqual(out.send.map(\.type), [IMFrameType.callHangup])
        XCTAssertEqual(out.send.first?.data["call_id"]?.stringValue, "c-1")
        XCTAssertEqual(out.state.call.state, .idle)
        XCTAssertEqual(out.state.room.state, .idle, "通话收了，房间也要一起归零")
        XCTAssertEqual(out.emit.map(\.callback), ["onCallEnd"])
        XCTAssertEqual(out.emit.first?.args["reason"]?.stringValue, "hangup")
        XCTAssertEqual(out.emit.first?.args["duration_sec"]?.intValue, 5)
    }

    /// frank 那一刻的形状：call.connected 到了、room.join 还在路上。
    func testConnectingWithJoinInFlightStillHangsUp() {
        let out = IMEngineMachine.forceEnd(inCall(.connecting, room: .joining))

        XCTAssertEqual(out.send.map(\.type), [IMFrameType.callHangup])
        XCTAssertEqual(out.state.room.state, .idle)
        XCTAssertTrue(out.state.room.buffered.isEmpty, "攒着的发布意图不能留到下一通")
    }

    func testRingingRejects() {
        let out = IMEngineMachine.forceEnd(inCall(.ringing))
        XCTAssertEqual(out.send.map(\.type), [IMFrameType.callReject])
        XCTAssertEqual(out.emit.first?.args["reason"]?.stringValue, "reject")
    }

    /// accept 有没有落地本端不知道：两帧都发，服务端那边总有一帧生效。
    func testAcceptingSendsRejectThenHangup() {
        let out = IMEngineMachine.forceEnd(inCall(.accepting))
        XCTAssertEqual(out.send.map(\.type), [IMFrameType.callReject, IMFrameType.callHangup])
        XCTAssertEqual(out.state.call.state, .idle)
    }

    /// invite.ok 还没回来就没有 call_id：发不了 cancel，但本地照样得收得掉。
    func testInvitingWithoutCallIDStillEndsLocally() {
        let out = IMEngineMachine.forceEnd(inCall(.inviting, callID: ""))
        XCTAssertTrue(out.send.isEmpty)
        XCTAssertEqual(out.state.call.state, .idle)
        XCTAssertEqual(out.emit.first?.args["reason"]?.stringValue, "cancel")
    }

    // MARK: - 会议与空闲

    func testMeetingLeavesTheRoom() {
        var ctx = IMEngineContext()
        ctx.room.state = .joined
        ctx.room.roomID = "r-9"

        let out = IMEngineMachine.forceEnd(ctx)

        XCTAssertEqual(out.send.map(\.type), [IMFrameType.roomLeave])
        XCTAssertEqual(out.send.first?.data["room_id"]?.stringValue, "r-9")
        XCTAssertEqual(out.state.room.state, .idle)
        XCTAssertEqual(out.emit.map(\.callback), ["onRoomLeft"], "会议没有 callEnd，收尾只能靠 roomLeft")
    }

    func testNothingToEndIsANoOp() {
        let out = IMEngineMachine.forceEnd(IMEngineContext())
        XCTAssertEqual(out.state, IMEngineContext())
        XCTAssertTrue(out.send.isEmpty)
        XCTAssertTrue(out.emit.isEmpty)
    }

    // MARK: - idle 下迟到的房间帧

    /// 收场之后才回来的 join.ok：**不认领，补发 room.leave**。
    func testLateJoinOKOnIdleRoomSendsLeaveAndStaysIdle() {
        let out = IMRoomMachine.reduce(IMRoomContext(), .recv(type: "room.join.ok", data: [
            "room_id": .string("r-1"), "participant_id": .string("r-1-p6"),
            "participants": .array([]), "tracks": .array([]),
        ]))

        XCTAssertEqual(out.state.state, .idle, "认领的话会把一个没人要的房间捡回来")
        XCTAssertEqual(out.send.map(\.type), [IMFrameType.roomLeave])
        XCTAssertEqual(out.send.first?.data["room_id"]?.stringValue, "r-1")
        XCTAssertTrue(out.emit.isEmpty, "宿主不该收到一个它早就离开的房间的 onRoomJoined")
    }

    func testLateRoomFramesOnIdleAreDropped() {
        let idle = IMRoomContext()
        let offer = IMRoomMachine.reduce(idle, .recv(type: IMFrameType.roomOffer,
                                                     data: ["pc": .string("sub"), "sdp": .string("v=0")]))
        XCTAssertTrue(offer.send.isEmpty, "应答的话会把 PeerConnection 重新建起来")

        let joined = IMRoomMachine.reduce(idle, .recv(type: IMFrameType.roomParticipantJoined,
                                                      data: ["uid": .string("bob")]))
        XCTAssertTrue(joined.emit.isEmpty)

        // 补发的那条 room.leave 的 .ok 回来时也落在这里：不能多抛一次 onRoomLeft。
        let leaveOK = IMRoomMachine.reduce(idle, .recv(type: "room.leave.ok", data: [:]))
        XCTAssertTrue(leaveOK.emit.isEmpty)
        XCTAssertEqual(leaveOK.state, idle)
    }

    // MARK: - idle 下迟到的通话帧

    /// 强制收场时 invite 还在路上：它回来了就补发 cancel，被叫才不会一直响到超时。
    func testLateInviteOKOnIdleCallSendsCancel() {
        let out = IMCallMachine.reduce(IMCallContext(), .recv(
            type: "call.invite.ok", data: ["call_id": .string("c-9"), "room_id": .string("r-9")]))

        XCTAssertEqual(out.send.map(\.type), [IMFrameType.callCancel])
        XCTAssertEqual(out.send.first?.data["call_id"]?.stringValue, "c-9")
        XCTAssertEqual(out.state, IMCallContext(), "本地已经收场了，不能把这通捡回来")
        XCTAssertTrue(out.emit.isEmpty)
    }

    /// cancel 来不及、对方已经接起来了：补发 hangup，服务端才不会一直把本端当成在通话里。
    func testLateConnectedOnIdleCallSendsHangup() {
        let out = IMCallMachine.reduce(IMCallContext(), .recv(type: IMFrameType.callConnected, data: [
            "call_id": .string("c-9"), "room_id": .string("r-9"), "room_token": .string("rt"),
        ]))

        XCTAssertEqual(out.send.map(\.type), [IMFrameType.callHangup])
        XCTAssertEqual(out.send.first?.data["call_id"]?.stringValue, "c-9")
        XCTAssertEqual(out.state, IMCallContext())
        XCTAssertTrue(out.emit.isEmpty, "不许发 room.join、也不许抛 onCallBegin")
    }

    /// 其余迟到帧照旧丢弃（向量 late_frames_in_idle_are_dropped）。
    func testOtherLateCallFramesOnIdleStayDropped() {
        let out = IMCallMachine.reduce(IMCallContext(), .recv(
            type: IMFrameType.callAccepted, data: ["call_id": .string("call-old"), "uid": .string("bob")]))
        XCTAssertTrue(out.send.isEmpty)
        XCTAssertTrue(out.emit.isEmpty)
    }
}
