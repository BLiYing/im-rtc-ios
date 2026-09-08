import XCTest
@testable import IMCallEngine

/*
 上行协商闸门。

 守的是真机 2026-09-08 iOS 日志里的这一串：

     event userVideoAvailable available=1 uid=alice
     (sdp_offer_answer.cc:4305): Called in wrong state: stable (INVALID_STATE)
     event error code=1501 name=internal

 发布 audio 与 video 两条轨道 → 两次 publish.ok → 两帧 room.offer{pub}。
 两个 offer 一起在飞，第二条 answer 回来时状态已经是 stable。
 那一次自愈了，但 Android 上同一个缺陷的后果是**上行再也协商不出去**。

 「帧泵是 actor 所以串行」挡不住这一类：`connection.request` 只等到
 `room.offer.ok`，answer 是随后一条独立的帧，整个回合不在串行范围内。
 */
final class PubOfferGateTests: XCTestCase {

    func testSecondOfferIsQueuedWhileTheFirstIsInFlight() {
        var gate = IMPubOfferGate()
        XCTAssertTrue(gate.begin(), "第一个应当放行")
        XCTAssertFalse(gate.begin(), "在飞时第二个必须排队——两个 offer 一起飞就是 INVALID_STATE")
        XCTAssertTrue(gate.isNegotiating)
    }

    func testFinishReportsTheQueuedOffer() {
        var gate = IMPubOfferGate()
        _ = gate.begin()
        _ = gate.begin() // 排队
        XCTAssertTrue(gate.finish(), "应当告诉调用方还欠一个 offer")
        XCTAssertFalse(gate.isNegotiating)
        XCTAssertFalse(gate.finish(), "没有排队的了，不该再补")
    }

    /// 失败也必须放闸。少放一处就是**永久卡死**，而且一条错误都没有。
    func testAbortReleasesTheGate() {
        var gate = IMPubOfferGate()
        _ = gate.begin()
        gate.abort()
        XCTAssertFalse(gate.isNegotiating)
        XCTAssertTrue(gate.begin(), "放闸之后应当能再发")
    }

    /*
      失败收场**不立刻**补，但那笔债要留着。

      排队标记的含义是「有人在我们忙着的时候要过一次协商，那次请求还没被服务」。
      这一轮失败并没有服务它——tracks 还是没协商过。所以 `abort()` 只放闸、
      **不清排队位**，等下一轮成功时一并补上。

      （这条用例第一版写反了：断言 abort 之后不欠。照那么改的话，
      「第二条轨道」会被悄悄丢掉、永远不发布，而且没有任何报错。）
    */
    func testAbortKeepsTheOutstandingDebt() {
        var gate = IMPubOfferGate()
        _ = gate.begin()
        _ = gate.begin() // 排队：第二条轨道还欠一次协商
        gate.abort()

        XCTAssertFalse(gate.isNegotiating, "失败也必须放闸")
        XCTAssertTrue(gate.begin(), "放闸之后应当能再发")
        XCTAssertTrue(gate.finish(), "那笔债还在——清掉的话第二条轨道就永远不发布了")
    }

    /*
      **这条直接对应 Android 上那个真机故障。**
      换了一条连接，之前那个 offer 的 answer 永远不会回来了（它是从旧 socket 发出去的）。
      不重置的话闸门一直关着，恢复后的重新协商只会排队，那条 PC 就此永久沉默。
    */
    func testResetLetsRenegotiationThroughAfterReconnect() {
        var gate = IMPubOfferGate()
        _ = gate.begin() // 断网前在飞的那个
        XCTAssertFalse(gate.begin(), "不重置的话恢复后只能排队")

        gate.reset()
        XCTAssertTrue(gate.begin(), "重置之后必须发得出去")
    }

    /// reset 连排队标记一起清：那一轮已经作废了，补它没有意义。
    func testResetClearsTheQueuedOfferToo() {
        var gate = IMPubOfferGate()
        _ = gate.begin()
        _ = gate.begin()
        gate.reset()
        _ = gate.begin()
        XCTAssertFalse(gate.finish(), "作废那一轮排下的 offer 不该被带到新连接上")
    }
}
