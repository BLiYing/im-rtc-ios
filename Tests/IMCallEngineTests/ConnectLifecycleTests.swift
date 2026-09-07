import XCTest
@testable import IMCallEngine

/// 连接生命周期里那几条**没有走通的路**：连不上、重复登录、帧的顺序。
///
/// 共同点是：**正常路径全绿，坏路径没人走过**。
/// 症状也一样难查——不是报错，是「卡住」「莫名其妙被踢」「格子里留了个走掉的人」。
final class ConnectLifecycleTests: XCTestCase {

    /// 连不上的 socket：resume 之后直接 onClose，**onOpen 永不触发**。
    /// 服务端没起来、DNS/TLS 失败、飞行模式，真机上都是这个形状。
    private final class NeverOpensSocket: IMWebSocket, @unchecked Sendable {
        var isOpen: Bool { false }
        func send(_ text: String) {}
        func close(code: Int, reason: String) {}
        func resume(handlers: IMWebSocketHandlers) {
            DispatchQueue.global().async { handlers.onClose(1001, "connection refused") }
        }
    }

    /// **login() 必须有结果**——哪怕是抛错。
    ///
    /// 旧实现把 continuation 只交给 onOpen 那条路，连不上时它悬着没人 resume：
    /// `login()` 既不返回也不抛，宿主的 catch 永远等不到，界面停在「连接中…」，
    /// 而 Swift 运行时会打出 `SWIFT TASK CONTINUATION MISUSE: connect() leaked
    /// its continuation`。这条用例就是拿来盯住那个泄漏的。
    func testLoginFailsInsteadOfHangingWhenSocketNeverOpens() async throws {
        let engine = IMCallEngine(url: URL(string: "ws://127.0.0.1:1/v1/ws")!,
                                  deviceID: "d-1", media: nil)
        engine.webSocketFactory = { _ in NeverOpensSocket() }

        let done = expectation(description: "login 有了结果")
        Task {
            do {
                try await engine.login("t")
                XCTFail("连不上还能登录成功？")
            } catch {
                XCTAssertTrue(error is IMRTCError, "抛的该是 IMRTCError：\(error)")
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)
    }

    /// 登录失败之后**还能再登**。
    ///
    /// 「已经登录了就拒掉」那道门要是不配上失败回滚，一次连不上就会把
    /// `connection` 永久留在那儿，之后每次重试都被自己那道门挡成 invalid_state
    /// ——比原来的 bug 还糟：用户从此再也登不上。
    func testRetryAfterFailedLoginIsAllowed() async throws {
        let engine = IMCallEngine(url: URL(string: "ws://127.0.0.1:1/v1/ws")!,
                                  deviceID: "d-1", media: nil)
        engine.webSocketFactory = { _ in NeverOpensSocket() }

        for attempt in 1...2 {
            do {
                try await engine.login("t")
                XCTFail("第 \(attempt) 次本该失败")
            } catch let error as IMRTCError {
                XCTAssertNotEqual(error.code, .invalidState,
                                  "第 \(attempt) 次被自己那道重复登录门挡住了——失败没回滚")
            }
        }
    }

    /// 已经登录了再 login 要就地拒掉。
    ///
    /// 不拦的话两条 WS 带着同一个 uid+device_id，服务端按顶号把先来的踢下线
    /// （handshake.go 的 4403），宿主收到一个**假的**「账号在别处登录」——
    /// 而所谓的别处就是这台机器自己。
    func testSecondLoginIsRejectedInsteadOfSelfKicking() async throws {
        let box = SocketBox()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!,
                                  deviceID: "d-1", media: nil)
        engine.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }

        async let first: Void = engine.login("token-1")
        let ws = try await waitForSocket(box)
        ws.open()
        let hello = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: hello.reqID))
        try await first

        do {
            try await engine.login("token-2")
            XCTFail("第二次 login 本该被拒")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code, .invalidState)
        }
        XCTAssertEqual(box.count, 1, "第二次 login 不该再开一条连接")
    }

    /**
     下行帧要**按线路顺序**进状态机。

     旧实现是每帧一个 `Task {}`：创建顺序确实是线路顺序，但无隔离的 Task 跑在
     全局并发执行器上，到达状态机的顺序没有保证。反序的后果很具体——
     `participant_joined` 与 `participant_left` 掉个个儿，离开先被空房间吃掉、
     加入再把人放回去，格子里就永远留着一个已经走了的人。

     一次灌 60 个 uid：靠运气全对的概率极低，乱序一定露馅。
     */
    func testInboundFramesReachTheMachineInWireOrder() async throws {
        let box = SocketBox()
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!,
                                  deviceID: "d-1", media: nil)
        engine.webSocketFactory = { _ in
            let socket = FakeWebSocket()
            box.set(socket)
            return socket
        }
        let seen = OrderBox()
        engine.addEventObserver { event in
            guard event.name == .userEnter else { return }
            seen.append(event.uid)
        }

        async let done: Void = engine.login("token-1")
        let ws = try await waitForSocket(box)
        ws.open()
        let hello = try await waitForFrame(ws, ofType: IMFrameType.hello)
        ws.receive(helloOKFrame(reqID: hello.reqID))
        try await done

        let uids = (0..<60).map { "u-\($0)" }
        for uid in uids {
            ws.receive("""
            {"type":"room.participant_joined","req_id":"","ts":1,"data":{"uid":"\(uid)"}}
            """)
        }
        for _ in 0..<200 where seen.all().count < uids.count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(seen.all(), uids, "帧到达状态机的顺序与线路顺序不一致")
    }

    // MARK: - 小工具（与 FacadeTests 里那两个同形；测试文件之间不互相 import）

    private func waitForSocket(_ box: SocketBox) async throws -> FakeWebSocket {
        for _ in 0..<200 {
            if let socket = box.get() { return socket }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没有建立连接")
    }

    private func waitForFrame(_ ws: FakeWebSocket,
                              ofType type: String) async throws -> IMEnvelope {
        for _ in 0..<400 {
            if let match = ws.frames().last(where: { $0.type == type }) { return match }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw IMRTCError(.internalError, "没等到帧 \(type)")
    }

}

/// 按顺序攒字符串，跨线程安全。
final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}
