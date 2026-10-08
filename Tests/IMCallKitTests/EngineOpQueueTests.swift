import XCTest
import IMCallEngine
@testable import IMCallKit

/// Kit 会话发给 Engine 的 logout / login 必须一个接一个地跑（`enqueueEngineOp`）。
///
/// 2026-10-08 真机：「清场 logout」与紧随其后的 login 各起一个独立 Task，交错执行时 logout 的
/// `stopFramePump()` 把 login 刚起的帧泵掐了——连接活着、应答照常，服务端推下来的来电 / 拒接全被丢掉。
final class EngineOpQueueTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @MainActor
    func testOpsRunStrictlyInOrderEvenWhenEarlierOneIsSlower() async {
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: nil)
        let controller = IMCallController(engine: engine)
        let log = Recorder()
        // 第一个操作故意慢（模拟 logout 里那段 await），第二个立刻就能跑完——不排队的话第二个会先完成。
        controller.enqueueEngineOp {
            log.add("logout-begin")
            try? await Task.sleep(nanoseconds: 50_000_000)
            log.add("logout-end")
        }
        controller.enqueueEngineOp { log.add("login") }
        await controller.engineOps?.value
        XCTAssertEqual(log.all, ["logout-begin", "logout-end", "login"])
    }
}
