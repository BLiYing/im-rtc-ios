import XCTest
@testable import IMCallEngine

/*
 画质档位。**三端同一张表**（Web 的 `media/videoProfile.ts`、这里、以后的 Android），
 而且 `maxBitrateBps` 要和服务端 `internal/sfu/bwe.go` 的 `bitrateHigh` 对得上——
 那边拿它做带宽预算，对不上的话降层判断是按一个错的数字做的。
 */
final class VideoProfileTests: XCTestCase {

    func testDefaultIs720p() {
        XCTAssertEqual(IMVideoProfile.default.name, "720p",
                       "1080p 在九宫格里没有意义，只是白烧上行带宽")
        XCTAssertEqual(IMVideoProfile.p720.maxBitrateBps, 1_500_000,
                       "要与服务端 bwe.go 的 bitrateHigh 一致")
    }

    /// simulcast 三层：h 满额、m 三分之一、l 十分之一（协议 §3.5）。
    func testSimulcastLayersScaleWithProfile() {
        let layers = IMVideoProfile.p1080.simulcastLayers
        XCTAssertEqual(layers.map(\.rid), ["h", "m", "l"])
        XCTAssertEqual(layers[0].bitrateBps, 3_000_000)
        XCTAssertEqual(layers[1].bitrateBps, 1_000_000)
        XCTAssertEqual(layers[2].bitrateBps, 300_000)
        XCTAssertEqual(layers.map(\.scaleDownBy), [1, 2, 4])
    }
}
