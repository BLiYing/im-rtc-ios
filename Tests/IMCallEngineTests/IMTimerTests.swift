import XCTest
@testable import IMCallEngine

/// `imAfter` / `imEvery`：返回的定时器已经 resume 过，cancel 之后不再响。
final class IMTimerTests: XCTestCase {
    private let queue = DispatchQueue(label: "imrtc.timer-tests")

    func testImAfterFiresOnceOnQueue() {
        let fired = expectation(description: "到点触发")
        var count = 0
        let timer = imAfter(.milliseconds(20), on: queue) {
            count += 1
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)
        queue.sync {} // 让可能的第二次回调有机会排进来
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(queue.sync { count }, 1, "一次性定时器只响一次")
        timer.cancel()
    }

    func testImAfterCancelledBeforeDeadlineNeverFires() {
        let never = expectation(description: "取消之后不该触发")
        never.isInverted = true
        let timer = imAfter(0.05, on: queue) { never.fulfill() }
        timer.cancel()
        wait(for: [never], timeout: 0.2)
    }

    func testImEveryFireNowRepeatsUntilCancelled() {
        let ticks = expectation(description: "立刻响一次，随后按间隔再响")
        ticks.expectedFulfillmentCount = 3
        var count = 0
        var timer: DispatchSourceTimer?
        timer = imEvery(0.01, fireNow: true, on: queue) {
            count += 1
            if count <= 3 { ticks.fulfill() }
            if count == 3 { timer?.cancel() }
        }
        wait(for: [ticks], timeout: 2)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(queue.sync { count }, 3, "cancel 之后不再响")
    }
}
