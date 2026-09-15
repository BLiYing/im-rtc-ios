import XCTest
@testable import IMCallEngine

/// 卡顿探针。时钟与通道全部注入，**不真的等、也不真的卡**。
final class StallProbeTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var ms: UInt64 = 1_000
        var now: UInt64 { lock.lock(); defer { lock.unlock() }; return ms }
        func advance(_ delta: UInt64) { lock.lock(); ms += delta; lock.unlock() }
    }

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(stalled: Bool, message: String, fields: [String: String])] = []
        func add(_ stalled: Bool, _ message: String, _ fields: [String: String]) {
            lock.lock(); items.append((stalled, message, fields)); lock.unlock()
        }
        var all: [(stalled: Bool, message: String, fields: [String: String])] {
            lock.lock(); defer { lock.unlock() }; return items
        }
    }

    /// 投进来的探针先扣着不跑，模拟通道被堵住；`release` 才放行。
    private final class Parked: @unchecked Sendable {
        private let lock = NSLock()
        private var dones: [@Sendable () -> Void] = []
        func park(_ done: @escaping @Sendable () -> Void) { lock.lock(); dones.append(done); lock.unlock() }
        func release() {
            lock.lock(); let pending = dones; dones = []; lock.unlock()
            pending.forEach { $0() }
        }
    }

    private func makeProbe(_ lane: IMStallProbe.Lane, clock: Clock,
                           reports: Reports) -> IMStallProbe {
        IMStallProbe(lanes: [lane], thresholdMS: 1_500, intervalMS: 500,
                     nowMS: { clock.now }, report: { reports.add($0, $1, $2) })
    }

    /// 堵住的通道**只报一次**，恢复时报实际卡了多久。
    func testStalledLaneIsReportedOnceThenRecoveryTellsHowLong() {
        let clock = Clock(), reports = Reports(), parked = Parked()
        let probe = makeProbe(.init(name: "concurrency_pool") { parked.park($0) },
                              clock: clock, reports: reports)

        probe.tickNow()
        for _ in 0..<2 { clock.advance(500); probe.tickNow() }
        XCTAssertTrue(reports.all.isEmpty, "1000ms 还没到阈值，不该报")

        clock.advance(500); probe.tickNow()
        clock.advance(500); probe.tickNow()
        XCTAssertEqual(reports.all.count, 1, "卡着不动也只报一次，不许每轮刷一条")
        XCTAssertEqual(reports.all.first?.stalled, true)
        XCTAssertEqual(reports.all.first?.fields["lane"], "concurrency_pool")
        XCTAssertEqual(reports.all.first?.fields["waited_ms"], "1500")

        clock.advance(300)
        parked.release()
        probe.drain()
        XCTAssertEqual(reports.all.count, 2)
        XCTAssertEqual(reports.all.last?.stalled, false)
        XCTAssertEqual(reports.all.last?.fields["stalled_ms"], "2300")
    }

    func testHealthyLaneStaysQuiet() {
        let clock = Clock(), reports = Reports()
        let probe = makeProbe(.init(name: "main") { $0() }, clock: clock, reports: reports)

        for _ in 0..<20 {
            probe.tickNow()
            probe.drain()
            clock.advance(500)
        }
        XCTAssertTrue(reports.all.isEmpty)
    }

    /// 探针自己隔了很久才被叫到（切后台、调试器暂停）：那一段不是哪条通道的锅。
    func testProcessSuspensionIsNotBlamedOnALane() {
        let clock = Clock(), reports = Reports(), parked = Parked()
        let probe = makeProbe(.init(name: "frame_loop") { parked.park($0) },
                              clock: clock, reports: reports)

        probe.tickNow()
        clock.advance(60_000)
        probe.tickNow()
        XCTAssertTrue(reports.all.isEmpty, "醒来那一刻量出来的 60 秒不能算成卡顿")

        // 挂起之前投出去的那枚回来了：作废，不能报一条「恢复」。
        parked.release()
        probe.drain()
        XCTAssertTrue(reports.all.isEmpty)
    }
}
