import XCTest
@testable import IMCallEngine

/// 统计字段挑选（`imStatsFields`）。iOS 开关摄像头前后那几行「上行视频采样」就靠它拼，
/// 而拼的那一侧（`IMUplinkVideoStats`）在 WebRTC target 里，macOS 上没法单测。
final class StatsFieldsTests: XCTestCase {

    func testCountsStayIntegers() {
        let fields = imStatsFields(["framesEncoded": NSNumber(value: 1234), "keyFramesEncoded": 3],
                                   keys: ["framesEncoded", "keyFramesEncoded"])
        XCTAssertEqual(fields, ["framesEncoded": "1234", "keyFramesEncoded": "3"])
    }

    func testFloatsKeepThreeDecimalsWithoutTrailingZeros() {
        let fields = imStatsFields([
            "targetBitrate": NSNumber(value: 1_500_000.0),
            "totalPacketSendDelay": 0.1 + 0.2,
            "framesPerSecond": NSNumber(value: 29.5),
        ], keys: ["targetBitrate", "totalPacketSendDelay", "framesPerSecond"])
        XCTAssertEqual(fields["targetBitrate"], "1500000")
        XCTAssertEqual(fields["totalPacketSendDelay"], "0.3")
        XCTAssertEqual(fields["framesPerSecond"], "29.5")
    }

    func testAbsentFieldsAreOmittedNotZero() {
        // 没编出过帧时统计里压根没有 frameWidth：写成 0 就和「真是 0」分不开了。
        let fields = imStatsFields(["qualityLimitationReason": "bandwidth"],
                                   keys: ["frameWidth", "qualityLimitationReason"])
        XCTAssertEqual(fields, ["qualityLimitationReason": "bandwidth"])
    }

    func testPrefixAppliedAndUnknownTypesSkipped() {
        let fields = imStatsFields(["width": NSNumber(value: 720), "odd": [1, 2]],
                                   keys: ["width", "odd"], prefix: "capture.")
        XCTAssertEqual(fields, ["capture.width": "720"])
    }
}
