import XCTest
@testable import IMCallEngine

/**
 回前台 / 网络变化：不再按退避白等（2026-09-18，与 Android `NetworkChangeReconnectTest` 对应）。

 现场：Wi-Fi 自己断开重连换了 IP，信令在退避 30 秒那一档空等，服务端 30 秒恢复窗口先到期，
 通话被结束。钉住 `SignalConnection+Nudge.swift` 的三种处境与防风暴间隔。
 用真时钟：退避第一档 1 秒（random=0.5 无抖动），「立刻」的判据是远小于那 1 秒。
 */
final class NetworkNudgeTests: XCTestCase {
    private func makeConnection() -> (IMSignalConnection, SocketBox) {
        let box = SocketBox()
        var options = IMConnectionOptions(url: URL(string: "ws://test/v1/ws")!,
                                          token: "test-token", deviceID: "d-1")
        options.requestTimeoutMS = 500
        options.random = { 0.5 }
        options.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        return (IMSignalConnection(options: options), box)
    }

    func testWaitingForBackoffReconnectsRightAwayOnNetworkChange() async throws {
        let (connection, box) = makeConnection()
        let first = try await handshake(connection, box)
        first.closeFromServer(IMCloseCode.goingAway) // 排上 1 秒后的重连

        let start = Date()
        connection.notifyNetworkChanged()
        _ = try await waitForNewSocket(box, after: first, within: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "网络变了不该再等退避那 1 秒")
    }

    func testForegroundReconnectsRightAwayWhileWaiting() async throws {
        let (connection, box) = makeConnection()
        let first = try await handshake(connection, box)
        first.closeFromServer(IMCloseCode.goingAway)

        connection.setAppForeground(true)
        _ = try await waitForNewSocket(box, after: first, within: 0.5)
    }

    func testBackgroundDoesNothing() async throws {
        let (connection, box) = makeConnection()
        let first = try await handshake(connection, box)
        let pings = first.frames().filter { $0.type == IMFrameType.ping }.count
        connection.setAppForeground(false)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(first.frames().filter { $0.type == IMFrameType.ping }.count, pings, "进后台不该探")
        XCTAssertNil(first.closedWith)
    }

    func testConnectedAndProbeAnsweredKeepsTheConnection() async throws {
        let (connection, box) = makeConnection()
        let ws = try await handshake(connection, box)

        connection.setAppForeground(true)
        let ping = try await waitForFrame(ws, ofType: IMFrameType.ping)
        ws.receive(#"{"type":"sys.pong","req_id":"\#(ping.reqID)","ts":1,"data":{}}"#)
        try await Task.sleep(nanoseconds: UInt64(NetworkProbe.probeMS + 300) * 1_000_000)

        XCTAssertNil(ws.closedWith, "活连接不许被误断")
        XCTAssertTrue(box.get() === ws)
        XCTAssertEqual(connection.currentState, .connected)
    }

    func testConnectedAndProbeUnansweredReconnectsWithoutBackoff() async throws {
        let (connection, box) = makeConnection()
        let ws = try await handshake(connection, box)

        let start = Date()
        connection.notifyNetworkChanged()
        _ = try await waitForFrame(ws, ofType: IMFrameType.ping)
        _ = try await waitForNewSocket(box, after: ws, within: Double(NetworkProbe.probeMS) / 1000 + 0.6)

        XCTAssertNotNil(ws.closedWith, "旧连接该被判死关掉")
        XCTAssertLessThan(Date().timeIntervalSince(start), Double(NetworkProbe.probeMS) / 1000 + 0.6,
                          "判死后该当场重连，不等退避那 1 秒")
    }

    func testInFlightAttemptThatFailsIsRetriedRightAway() async throws {
        let (connection, box) = makeConnection()
        let first = try await handshake(connection, box)
        first.closeFromServer(IMCloseCode.goingAway)
        let second = try await waitForNewSocket(box, after: first, within: 1.5) // 退避 1 秒后正在连

        connection.notifyNetworkChanged()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(box.get() === second, "正在连的那次让它跑完，不另开")

        second.closeFromServer(IMCloseCode.goingAway) // 这次没连上；不管它，下一档本该是 2 秒
        _ = try await waitForNewSocket(box, after: second, within: 0.5)
    }

    func testTwoNudgesInARowAreAtLeastTwoSecondsApart() async throws {
        let (connection, box) = makeConnection()
        let first = try await handshake(connection, box)
        first.closeFromServer(IMCloseCode.goingAway)
        connection.notifyNetworkChanged()
        let second = try await waitForNewSocket(box, after: first, within: 0.5)

        second.closeFromServer(IMCloseCode.goingAway) // 退避排 1 秒
        try await Task.sleep(nanoseconds: 50_000_000)
        connection.notifyNetworkChanged() // 紧跟着再变一次：要补足 2 秒间隔
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertTrue(box.get() === second, "距上次立刻重连不足 2 秒，不许再连（也不许走退避那 1 秒）")
        _ = try await waitForNewSocket(box, after: second, within: 1.0)
    }

    func testNotLoggedInOrLoggedOutDoesNothing() async throws {
        let (connection, box) = makeConnection()
        connection.notifyNetworkChanged()
        connection.setAppForeground(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(box.get())

        let ws = try await handshake(connection, box)
        connection.close()
        connection.notifyNetworkChanged()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(box.get() === ws)
        XCTAssertEqual(ws.frames().filter { $0.type == IMFrameType.ping }.count, 0)
    }

    // MARK: - 夹具

    private func handshake(_ connection: IMSignalConnection, _ box: SocketBox) async throws -> FakeWebSocket {
        async let hello = connection.connect()
        let ws = try await waitForNewSocket(box, after: nil, within: 1.0)
        ws.open()
        let frame = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: frame.reqID))
        _ = try await hello
        return ws
    }

    private func waitForNewSocket(_ box: SocketBox, after previous: FakeWebSocket?,
                                  within seconds: Double) async throws -> FakeWebSocket {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let socket = box.get(), socket !== previous { return socket }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "\(seconds) 秒内没等到新连接")
    }

    private func waitForFrame(_ ws: FakeWebSocket, ofType type: String) async throws -> IMEnvelope {
        for _ in 0..<200 {
            if let match = ws.frames().last(where: { $0.type == type }) { return match }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到帧 \(type)")
    }
}
