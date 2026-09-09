import XCTest
@testable import IMCallEngine

/// 「裁切填满还是留黑边」的判据。
///
/// 三条主用例就是 `im-rtc-server/docs/mechanism/VIDEO_RENDERING.md` 里那张表，
/// **数字一一对应**——那张表是规范，这里是它的可执行版本。
/// Android 侧的 `VideoFitTest` 跑的是同一组数（那边多一个旋转参数，见 IMVideoFit 的注释）。
final class VideoFitTests: XCTestCase {

    func testSquareTileWithPortraitSourceSitsExactlyOnThreshold() {
        // 九宫格正方形格子 + 竖屏源：正好落在阈值上，该填满。
        let fraction = imVisibleFraction(
            videoWidth: 720, videoHeight: 1280, viewWidth: 350, viewHeight: 350)
        XCTAssertEqual(fraction, 0.5625, accuracy: 0.001)
        XCTAssertTrue(fraction >= imMinVisibleFraction,
                      "正好等于阈值要算填满，否则九宫格白留两条宽黑边")
        XCTAssertTrue(imShouldFillVideo(
            videoWidth: 720, videoHeight: 1280, viewWidth: 350, viewHeight: 350))
    }

    func testPortraitFullscreenWithPortraitSourceFills() {
        let fraction = imVisibleFraction(
            videoWidth: 720, videoHeight: 1280, viewWidth: 1080, viewHeight: 2200)
        XCTAssertEqual(fraction, 0.873, accuracy: 0.01)
        XCTAssertTrue(imShouldFillVideo(
            videoWidth: 720, videoHeight: 1280, viewWidth: 1080, viewHeight: 2200))
    }

    func testPortraitFullscreenWithLandscapeSourceMustLetterbox() {
        // 这一条是整条规则的理由：填满会是 3 倍放大 + 砍掉 72% 的宽。
        let fraction = imVisibleFraction(
            videoWidth: 1280, videoHeight: 720, viewWidth: 1080, viewHeight: 2200)
        XCTAssertEqual(fraction, 0.276, accuracy: 0.01)
        XCTAssertFalse(imShouldFillVideo(
            videoWidth: 1280, videoHeight: 720, viewWidth: 1080, viewHeight: 2200))
    }

    func testUnmeasuredSizesFillRatherThanShowBars() {
        XCTAssertEqual(imVisibleFraction(
            videoWidth: 1280, videoHeight: 720, viewWidth: 0, viewHeight: 0), 0)
        XCTAssertTrue(imShouldFillVideo(
            videoWidth: 1280, videoHeight: 720, viewWidth: 0, viewHeight: 0),
                      "还没 layout 的那一拍该先填满，别先露一圈黑边")
        XCTAssertTrue(imShouldFillVideo(
            videoWidth: 0, videoHeight: 0, viewWidth: 350, viewHeight: 350),
                      "帧尺寸还没来也一样")
    }

    func testMatchingAspectKeepsWholeFrame() {
        XCTAssertEqual(imVisibleFraction(
            videoWidth: 1280, videoHeight: 720, viewWidth: 640, viewHeight: 360),
                       1, accuracy: 0.001)
    }

    func testThresholdIsNineSixteenths() {
        // 钉住这个数：它与 Android 的 IMVideoFit.MIN_VISIBLE_FRACTION 必须一致，
        // 也与 libwebrtc 的 BALANCED_VISIBLE_FRACTION 同值。
        XCTAssertEqual(imMinVisibleFraction, 9.0 / 16.0, accuracy: 0.0001)
    }
}
