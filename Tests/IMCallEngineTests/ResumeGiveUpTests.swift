import XCTest
@testable import IMCallEngine

/*
 「断得太久 → 服务端那一侧的会话已经没了」这条倒计时。

 守的是真机 2026-09-08 的一幕：iOS carol 断网后停在「正在重连」，
 **不接网就永远停在通话界面，连挂断都点不动**——本地放弃的唯一入口是
 「重连上了但 resumed == false」，而网络不回来那一刻永远不会到。
 （挂断只产出一帧发不出去的 `call.hangup`，本地状态一动不动，
 这是 §4.2 铁律 1 的直接后果，不是 bug。）

 这一层全是时序，不测就等于没写（CONVENTIONS §9）。
 */
final class ResumeGiveUpTests: XCTestCase {

    /// 连不上的 socket：resume 之后直接 onClose，**onOpen 永不触发**。飞行模式就是这个形状。
    private final class NeverOpensSocket: IMWebSocket, @unchecked Sendable {
        var isOpen: Bool { false }
        func send(_ text: String) {}
        func close(code: Int, reason: String) {}
        func resume(handlers: IMWebSocketHandlers) {
            DispatchQueue.global().async { handlers.onClose(1006, "network down") }
        }
    }

    private func options(giveUpMS: Int?) -> IMConnectionOptions {
        var opts = IMConnectionOptions(url: URL(string: "ws://127.0.0.1:1/v1/ws")!,
                                       token: "t", deviceID: "d-1")
        opts.webSocketFactory = { _ in NeverOpensSocket() }
        opts.resumeGiveUpDelayMSForTesting = giveUpMS
        // 退避的随机抖动固定住，省得用例时快时慢。
        opts.random = { 0.5 }
        return opts
    }

    /*
      **上界不能拍脑袋。** 服务端那 30 秒不是从我们断开算起的，是从**它自己察觉**算起，
      而它要连续 3 个心跳周期收不到东西才察觉（§1.3）。按默认 15 秒心跳，
      最晚的到期时刻是断开后 3×15 + 30 = 75 秒。

      取短了就会撒谎：真机上断开 14 秒后重连**成功恢复**，通话好端端地继续；
      在那之前宣布「通话已结束」是把一通还能救回来的电话杀掉，
      而且服务端还认为我们在房里，房间会挂着一个幽灵成员。
    */
    func testGiveUpDelayCoversServerReadTimeoutPlusResumeWindow() {
        let connection = IMSignalConnection(options: options(giveUpMS: nil))
        let expected = (IMSignalConnection.serverDeathPings * 15
            + IMSignalConnection.resumeWindowSec
            + IMSignalConnection.giveUpGraceSec) * 1000

        XCTAssertEqual(connection.giveUpDelayMS, expected)
        XCTAssertGreaterThan(
            connection.giveUpDelayMS,
            (IMSignalConnection.resumeWindowSec + IMSignalConnection.serverDeathPings * 15) * 1000 - 1,
            "只按恢复窗口那 30 秒算，会在服务端还能恢复的时候就宣布通话结束")
    }

    /// 网络一直不回来时也要放弃——少了它界面永远停在「正在重连」。
    func testFiresWhenReconnectNeverSucceeds() async throws {
        var events = IMConnectionEvents()
        let fired = expectation(description: "报了会话不可恢复")
        events.onSessionUnrecoverable = { fired.fulfill() }
        let connection = IMSignalConnection(options: options(giveUpMS: 300), events: events)

        _ = try? await connection.connect()
        await fulfillment(of: [fired], timeout: 5.0)
    }

    /*
      **每次重连失败都重排的话，截止时刻就一直往后挪、永远不会到**——
      而那正是这条倒计时要治的病。起点必须是第一次断开的那一刻。

      NeverOpensSocket 每次 connect 都立刻 onClose，退避表会一次次把它排回来；
      倒计时若跟着重排，下面这一等就永远等不到。
    */
    func testDeadlineIsNotPushedBackByRepeatedReconnectFailures() async throws {
        var events = IMConnectionEvents()
        let fired = expectation(description: "报了会话不可恢复")
        let elapsed = DeadlineBox()
        let started = Date()
        events.onSessionUnrecoverable = {
            elapsed.mark(Date().timeIntervalSince(started))
            fired.fulfill()
        }
        let connection = IMSignalConnection(options: options(giveUpMS: 1_200), events: events)

        _ = try? await connection.connect()
        await fulfillment(of: [fired], timeout: 6.0)

        /*
          **只等「响没响」是抓不住这条的**：重排只是把时刻往后推，退避表越走越疏
          （1s→2s→4s→…→30s），总有一次空隙让它响出来，于是用例照样绿。
          第一版就是这么写的，把 `guard unrecoverableTimer == nil` 去掉照样通过。

          所以要量**什么时候**响：退避第一次撞墙在 1 秒左右，一旦重排，
          截止时刻就被推到 2.2 秒开外。这里卡在 1.9 秒。
          生产里 giveUpMS 是 80 秒、退避封顶 30 秒，重排的话它**永远不会响**。
        */
        guard let seconds = elapsed.value else { return XCTFail("没响") }
        XCTAssertLessThan(seconds, 1.9,
                          "截止时刻被重连失败往后推了（\(seconds)s）——生产上退避封顶 30 秒，推下去就永远不会响")
    }

    /// logout 之后不许再有任何回调——宿主已经把一切拆掉了。
    func testLogoutCancelsTheCountdown() async throws {
        var events = IMConnectionEvents()
        let fired = expectation(description: "不该报")
        fired.isInverted = true
        events.onSessionUnrecoverable = { fired.fulfill() }
        let connection = IMSignalConnection(options: options(giveUpMS: 300), events: events)

        _ = try? await connection.connect()
        connection.close()
        await fulfillment(of: [fired], timeout: 1.5)
    }
}

/*
 状态机这一半：收到 `session_unrecoverable` 要**本地合成终局**。

 与「重连上了但 resumed == false」走的是同一段逻辑，差别只在不必等重连成功。
 */
final class SessionUnrecoverableMachineTests: XCTestCase {

    func testSynthesizesNetworkEndAndClearsTheRoom() {
        var ctx = IMEngineContext()
        let placed = IMEngineMachine.reduce(ctx, .act(op: "call", args: [
            "callee_ids": .array([.string("bob")]),
            "media_type": .string("audio"),
            "is_group": .bool(false),
        ]))
        ctx = placed.state
        XCTAssertNotEqual(ctx.call.state, .idle)

        let out = IMEngineMachine.reduce(ctx, .internalEvent(name: "session_unrecoverable"))

        XCTAssertEqual(out.state.call.state, .idle,
                       "不回 idle 的话界面永远停在通话页，挂断也点不动")
        XCTAssertEqual(out.state.room.state, .idle, "服务端那边房间早没了，本地不能装作还在")
        let ends = out.emit.filter { $0.callback == "onCallEnd" }
        XCTAssertEqual(ends.count, 1, "终局帧只许抛一条（不变量 I8）")
        XCTAssertEqual(ends.first?.args["reason"]?.stringValue, "network")
    }

    /// 本来就没有通话时是空操作——**不许凭空抛一条 onCallEnd**。
    func testIdleStaysQuiet() {
        let out = IMEngineMachine.reduce(IMEngineContext(), .internalEvent(name: "session_unrecoverable"))
        XCTAssertTrue(out.emit.filter { $0.callback == "onCallEnd" }.isEmpty)
    }
}
