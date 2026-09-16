import XCTest
@testable import IMCallEngine

/// 插拔耳机 / 蓝牙之后，强制外放被系统清掉要补回去；别的情况一律不碰路由（CLIENT_PARITY `[^audioroute]`）。
final class AudioRoutePolicyTests: XCTestCase {

    func testReappliesSpeakerWhenPlugClearsOverride() {
        XCTAssertTrue(imShouldReapplySpeaker(wantsSpeaker: true, reason: 1, outputPorts: ["Headphones"]),
                      "插上耳机，外放覆盖被清掉：补回扬声器")
        XCTAssertTrue(imShouldReapplySpeaker(wantsSpeaker: true, reason: 2, outputPorts: ["Receiver"]),
                      "拔掉蓝牙回落到听筒：补回扬声器")
    }

    func testLeavesRouteAloneOtherwise() {
        XCTAssertFalse(imShouldReapplySpeaker(wantsSpeaker: false, reason: 1, outputPorts: ["Headphones"]),
                       "没开外放：跟随系统，插耳机就走耳机")
        XCTAssertFalse(imShouldReapplySpeaker(wantsSpeaker: true, reason: 1, outputPorts: ["Speaker"]),
                       "还在扬声器上：不重复设")
        XCTAssertFalse(imShouldReapplySpeaker(wantsSpeaker: true, reason: 4, outputPorts: ["Receiver"]),
                       "override（我们自己改的）之类的原因不接，免得自激")
    }
}
