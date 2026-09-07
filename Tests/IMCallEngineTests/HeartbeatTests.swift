import XCTest
@testable import IMCallEngine

/// 心跳判死的时机（协议 §1.3）。
///
/// 这一层以前**一个用例都没有**——而它恰恰是 CONVENTIONS §9 点名要写测试的那类：
/// 纯时序，连真连接都看不出对错，只有假时钟和秒表说了算。
final class HeartbeatTests: XCTestCase {

    /// 心跳按协议 §1.3 判死：**连续 3 个周期**，不是 4 个。
    ///
    /// 写成 `missed > missLimit` 的话第 3 个周期还在发 ping，要到第 4 个才判死
    /// （默认 15s 就是 60s 而不是 45s）。这一档差别在半开连接上是实打实的：
    /// 服务端的关闭帧到不了本机，本机这个定时器是唯一的探测手段。
    func testHeartbeatDeclaresDeadAfterExactlyMissLimitPeriods() async throws {
        let queue = DispatchQueue(label: "test.heartbeat")
        let deadAt = DeadlineBox()
        let started = Date()
        let heartbeat = Heartbeat(queue: queue,
                                  sendPing: {},
                                  onDead: { deadAt.mark(Date().timeIntervalSince(started)) })
        heartbeat.start(intervalSec: 1)
        defer { heartbeat.stop() }

        // 3 个周期 ≈ 3s。给 1s 余量，但必须**明显早于** 4s——那是差一的那个答案。
        try await Task.sleep(nanoseconds: 3_600_000_000)
        guard let elapsed = deadAt.value else {
            return XCTFail("3 个周期过去了还没判死：missLimit 的比较写成了 > 而不是 >=")
        }
        XCTAssertGreaterThan(elapsed, 2.5, "不该提前判死")
        XCTAssertLessThan(elapsed, 3.6, "第 4 个周期才判死 = 差一")
    }

    /// 收到任何帧都算对端活着，计数要归零（§1.3）。
    func testAnyFrameResetsTheMissCounter() {
        let queue = DispatchQueue(label: "test.heartbeat.reset")
        let heartbeat = Heartbeat(queue: queue, sendPing: {}, onDead: {})
        heartbeat.noteFrameReceived()
        XCTAssertEqual(heartbeat.missedBeats, 0)
    }
}

/// 记一个时刻，跨线程安全。
final class DeadlineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval?
    func mark(_ value: TimeInterval) {
        lock.lock(); if seconds == nil { seconds = value }; lock.unlock()
    }
    var value: TimeInterval? { lock.lock(); defer { lock.unlock() }; return seconds }
}
