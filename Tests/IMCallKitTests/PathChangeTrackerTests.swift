import XCTest
@testable import IMCallKit

/// `IMPathChangeTracker`：只有「换了网络」才通知 Engine，开始监听时那一下不算。
final class PathChangeTrackerTests: XCTestCase {
    private let tracker = IMPathChangeTracker()

    func testFirstUpdateIsNotAChange() {
        XCTAssertFalse(tracker.observe(satisfied: true, signature: "wifi"))
    }

    func testSameSignatureIsNotAChange() {
        _ = tracker.observe(satisfied: true, signature: "wifi")
        XCTAssertFalse(tracker.observe(satisfied: true, signature: "wifi"), "只是昂贵 / 受限标志变了")
    }

    func testDifferentSignatureIsAChange() {
        _ = tracker.observe(satisfied: true, signature: "wifi")
        XCTAssertTrue(tracker.observe(satisfied: true, signature: "cellular"))
    }

    func testLostThenBackIsAChangeEvenIfSame() {
        _ = tracker.observe(satisfied: true, signature: "wifi")
        XCTAssertFalse(tracker.observe(satisfied: false, signature: ""), "没网可连不报")
        XCTAssertTrue(tracker.observe(satisfied: true, signature: "wifi"), "中间断过，旧连接大概率已死")
    }

    func testStartingOfflineThenOnlineIsAChange() {
        _ = tracker.observe(satisfied: false, signature: "")
        XCTAssertTrue(tracker.observe(satisfied: true, signature: "wifi"))
    }
}
