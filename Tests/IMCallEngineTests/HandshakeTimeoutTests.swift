import XCTest
@testable import IMCallEngine

/**
 握手超时与旧 socket 收尾（2026-09-19，与 Android `closeAndReconnect`、Web `retireStaleSocket` 对应）。

 现场在 Web：服务端注入 silence（丢下行、不关 socket），hello 等应答超时后那条 socket 没人关，
 重连只挂在关闭事件上，于是干等服务端 45 秒读超时；换了新 socket 后旧的迟到关闭又把新连接当成断了。
 */
final class HandshakeTimeoutTests: XCTestCase {
    private func makeConnection() -> (IMSignalConnection, SocketBox) {
        let box = SocketBox()
        var options = IMConnectionOptions(url: URL(string: "ws://test/v1/ws")!,
                                          token: "test-token", deviceID: "d-1")
        options.requestTimeoutMS = 300
        options.random = { 0.5 }
        options.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        return (IMSignalConnection(options: options), box)
    }

    /// hello 等应答超时：本端关掉那条 socket（1001），并照常排重连——不等服务端读超时。
    func testHelloTimeoutClosesSocketAndReconnects() async throws {
        let (connection, box) = makeConnection()
        async let hello = connection.connect()
        let first = try await waitForNewSocket(box, after: nil, within: 1.0)
        first.open()
        _ = try await waitForFrame(first, ofType: IMFrameType.hello)

        do {
            _ = try await hello
            XCTFail("本该超时")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .signalingTimeout)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(first.closedWith, IMCloseCode.goingAway, "超时的那条要本端关掉，且不能用 1000（那是 logout）")
        // 退避第一档 1 秒（random=0.5 无抖动）。
        _ = try await waitForNewSocket(box, after: first, within: 2.0)
    }

    /// 服务端明确拒了握手时**不抢着关**：关闭码要留给服务端（4401 计数靠它）。
    func testHelloRejectedLeavesCloseToServer() async throws {
        let (connection, box) = makeConnection()
        async let hello = connection.connect()
        let ws = try await waitForNewSocket(box, after: nil, within: 1.0)
        ws.open()
        let frame = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(#"{"type":"sys.error","req_id":"\#(frame.reqID)","ts":1,"data":{"code":1001,"msg":"token","for_type":"sys.hello"}}"#)
        _ = try? await hello
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(ws.closedWith)
    }

    /// 握手还在飞时又开一次连接：旧的要关掉，它迟到的关闭事件不许把新连接当成断了。
    func testStaleSocketCloseDoesNotTearDownNewConnection() async throws {
        let (connection, box) = makeConnection()
        async let firstAttempt = connection.connect()
        let stale = try await waitForNewSocket(box, after: nil, within: 1.0)
        stale.open()
        _ = try await waitForFrame(stale, ofType: IMFrameType.hello)

        async let secondAttempt = connection.connect()
        let current = try await waitForNewSocket(box, after: stale, within: 1.0)
        XCTAssertEqual(stale.closedWith, IMCloseCode.goingAway, "被取代的 socket 要关掉，不能泄漏")
        _ = try? await firstAttempt

        current.open()
        let frame = try await waitForFrame(current, ofType: IMFrameType.hello)
        current.receive(helloOKFrame(reqID: frame.reqID))
        _ = try await secondAttempt

        stale.deliverLateClose(IMCloseCode.kickedOut)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(connection.currentState, .connected)
        XCTAssertNil(current.closedWith)
        XCTAssertEqual(box.count, 2, "旧 socket 的关闭不该再排一轮重连")
    }

    // MARK: - 夹具

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
