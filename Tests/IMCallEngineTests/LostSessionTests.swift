import XCTest
@testable import IMCallEngine

/*
 「服务端那侧的会话没了」之后，**宿主必须拿到一个收场信号**。

 有 call 的场合一直有 `onCallEnd(network)` 兜着（不变量 I8），可**会议是直接 joinRoom 的、
 压根没有 call**：`IMRoomMachine.resume(_:resumed: false)` 只是把房间清成 idle，
 一个事件都不抛。于是房间机悄悄回了 idle，而界面还显示着「会议中」、计时器还在走，
 用户完全不知道自己已经掉出去了；更糟的是一个结束类回调都没抛，
 `IMFrameLoop` 的 `leaveCallbacks` 不命中 → `media.close()` 永远不调用，
 摄像头麦克风一直开着，上一轮的 PeerConnection 还会被带进下一次进房。

 **这一条三端同源**：Web 与 Android 同日补上同一段（`dropLostSession`）。
*/
final class LostSessionTests: XCTestCase {

    // MARK: - 会议（没有 call）

    /// 重连回来发现会话没了：房间回 idle，**并且要抛 onRoomLeft**。
    func testMeetingNotResumedEmitsRoomLeft() {
        let ctx = inMeeting()

        let result = IMEngineMachine.reduce(ctx, helloOK(resumed: false), nowMS: 1_757_000_000_000)

        XCTAssertEqual(result.state.room.state, .idle)
        XCTAssertEqual(result.emit.map(\.callback), ["onConnected", "onRoomLeft"],
                       "会议没有 callEnd，onRoomLeft 是它唯一的收场信号")
        XCTAssertEqual(result.emit.last?.args["room_id"]?.stringValue, "r-9")
    }

    /// 断太久（`session_unrecoverable`）走的是同一条收场路径——差别只在不必等重连成功。
    func testMeetingSessionUnrecoverableEmitsRoomLeft() {
        let ctx = inMeeting()

        let result = IMEngineMachine.reduce(ctx, .internalEvent(name: "session_unrecoverable"),
                                            nowMS: 1_757_000_000_000)

        XCTAssertEqual(result.state.room.state, .idle)
        XCTAssertEqual(result.emit.map(\.callback), ["onRoomLeft"])
    }

    // MARK: - 通话（有 call）

    /// **有通话时不能补 onRoomLeft**：`onCallEnd` 是所有结束分支的唯一出口（设计 §7.5），
    /// 为同一件事抛两个回调会让宿主的记账重复一次。
    /// 这条也是一致性向量 `reconnect_not_resumed_synthesizes_call_end` 钉住的行为。
    func testCallNotResumedStillOnlyEmitsCallEnd() {
        var ctx = inMeeting()
        ctx.call.state = .connected
        ctx.call.callID = "call-1"
        ctx.call.connectedAtMS = 1_757_000_000_000

        let result = IMEngineMachine.reduce(ctx, helloOK(resumed: false), nowMS: 1_757_000_060_000)

        XCTAssertEqual(result.emit.map(\.callback), ["onConnected", "onCallEnd"],
                       "有 callEnd 兜着就不该再补一条 onRoomLeft")
        XCTAssertEqual(result.state.call.state, .idle)
        XCTAssertEqual(result.state.room.state, .idle)
    }

    // MARK: - 边界

    /// 本来就在 idle：只报连接，不凭空抛一条离房。
    func testIdleNotResumedEmitsOnlyConnected() {
        let result = IMEngineMachine.reduce(IMEngineContext(), helloOK(resumed: false),
                                            nowMS: 1_757_000_000_000)
        XCTAssertEqual(result.emit.map(\.callback), ["onConnected"])
    }

    /// `resumed == true` 这条路一个字都不该变：房间留着，不抛离房。
    func testResumedKeepsRoom() {
        var ctx = inMeeting()
        ctx.room.state = .reconnecting

        let result = IMEngineMachine.reduce(ctx, helloOK(resumed: true), nowMS: 1_757_000_000_000)

        XCTAssertEqual(result.state.room.state, .joined)
        XCTAssertEqual(result.emit.map(\.callback), ["onConnected"])
    }

    // MARK: - 辅助

    private func inMeeting() -> IMEngineContext {
        var room = IMRoomContext()
        room.state = .joined
        room.didJoin = true
        room.roomID = "r-9"
        room.roomToken = "rt-9"
        var ctx = IMEngineContext()
        ctx.room = room
        return ctx
    }

    private func helloOK(resumed: Bool) -> IMMachineInput {
        .recv(type: IMEnvelope.okType(IMFrameType.hello),
              data: ["session_id": .string("s-2"), "resumed": .bool(resumed)])
    }
}
