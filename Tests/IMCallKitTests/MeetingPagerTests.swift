import XCTest
@testable import IMCallKit

/**
 会议分页画廊与第一页的发言人优先（MEETING_ROOM_DESIGN §4.1 / §4.2）。

 §4.2 的三条规则全是**时间闸**，而时间闸最容易写成「差不多能用」：
 少一条就是格子每 300ms 跳一次，多一条就是说了半天也换不上去。
 所以每一条各有一条用例，**三端跑同一组场景**（Web 的 `firstPage.test.ts`、
 Android 的 `MeetingPagerTest`）。
 */
final class MeetingPagerTests: XCTestCase {

    private let firstPageSize = IMMeetingRemotesPerPage

    private func names(_ count: Int) -> [String] {
        (1...count).map { "u\($0)" }
    }

    private func input(uids: [String]? = nil, speaking: Set<String> = [],
                       withVideo: Set<String>? = nil, pinned: String = "",
                       nowMS: Int64) -> IMFirstPageInput {
        let people = uids ?? names(10)
        return IMFirstPageInput(uids: people, speaking: speaking,
                                withVideo: withVideo ?? Set(people), pinned: pinned,
                                firstPageSize: firstPageSize, nowMS: nowMS)
    }

    /// settle 把所有人在第一页的驻留时间熬过 10 s，好让后面的用例能真的换人。
    private func settle(_ uids: [String]? = nil) -> (state: IMFirstPageState, nowMS: Int64) {
        var state = imReorderFirstPage(IMFirstPageState(), input(uids: uids, nowMS: 0))
        let nowMS = IMMinStayMS + 1
        state = imReorderFirstPage(state, input(uids: uids, nowMS: nowMS))
        return (state, nowMS)
    }

    private func firstPage(_ state: IMFirstPageState) -> [String] {
        Array(state.order.prefix(firstPageSize))
    }

    // MARK: - 发言人优先

    func testFirstOrderIsJoinOrder() {
        let state = imReorderFirstPage(IMFirstPageState(), input(nowMS: 1_000))
        XCTAssertEqual(state.order, names(10))
    }

    func testPromotesOnlyAfterSpeakingLongEnough() {
        let base = settle()
        let speaking: Set<String> = ["u10"]

        // 刚开口：记下起点，但不换。
        var state = imReorderFirstPage(base.state, input(speaking: speaking, nowMS: base.nowMS))
        XCTAssertFalse(firstPage(state).contains("u10"))

        // 差一点点也不换——1.4 s 的咳嗽不该把人顶上来。
        state = imReorderFirstPage(state, input(speaking: speaking,
                                                nowMS: base.nowMS + IMPromoteAfterMS - 100))
        XCTAssertFalse(firstPage(state).contains("u10"))

        state = imReorderFirstPage(state, input(speaking: speaking,
                                                nowMS: base.nowMS + IMPromoteAfterMS))
        XCTAssertTrue(firstPage(state).contains("u10"), "说够 1.5 s 就该换进第一页")
    }

    func testEvictsTheOneWhoSpokeLongestAgo() {
        let base = settle()
        // u3 最近说过话，u1 从没说过：该走的是 u1。
        var state = imReorderFirstPage(base.state, input(speaking: ["u3"], nowMS: base.nowMS))
        let now = base.nowMS + IMSwapCooldownMS + IMPromoteAfterMS
        state = imReorderFirstPage(state, input(speaking: ["u10"], nowMS: now - IMPromoteAfterMS))
        state = imReorderFirstPage(state, input(speaking: ["u10"], nowMS: now))

        XCTAssertTrue(firstPage(state).contains("u10"))
        XCTAssertTrue(firstPage(state).contains("u3"))
        XCTAssertFalse(firstPage(state).contains("u1"))
    }

    func testPrefersEvictingSomeoneWithoutCamera() {
        let base = settle()
        let withVideo = Set(names(10).filter { $0 != "u2" })
        var state = imReorderFirstPage(
            base.state, input(speaking: ["u10"], withVideo: withVideo, nowMS: base.nowMS))
        state = imReorderFirstPage(
            state, input(speaking: ["u10"], withVideo: withVideo,
                         nowMS: base.nowMS + IMPromoteAfterMS))
        XCTAssertFalse(firstPage(state).contains("u2"), "同样久没说话时先换没开摄像头的")
    }

    func testNewcomerIsNotEvictedWithinTenSeconds() {
        let base = settle()
        var state = imReorderFirstPage(base.state, input(speaking: ["u10"], nowMS: base.nowMS))
        let promotedAt = base.nowMS + IMPromoteAfterMS
        state = imReorderFirstPage(state, input(speaking: ["u10"], nowMS: promotedAt))
        XCTAssertTrue(firstPage(state).contains("u10"))

        // 紧接着 u9 也说够了：这时第一页里只有 u10 是「新来的」，别人都熬过 10 s，
        // 所以该被换走的是别人，u10 必须还在。
        let later = promotedAt + IMSwapCooldownMS + IMPromoteAfterMS
        state = imReorderFirstPage(state, input(speaking: ["u9"], nowMS: later - IMPromoteAfterMS))
        state = imReorderFirstPage(state, input(speaking: ["u9"], nowMS: later))
        XCTAssertTrue(firstPage(state).contains("u10"))
        XCTAssertTrue(firstPage(state).contains("u9"))
    }

    func testAtMostOneSwapPerCooldown() {
        let base = settle()
        let both: Set<String> = ["u9", "u10"]
        var state = imReorderFirstPage(base.state, input(speaking: both, nowMS: base.nowMS))
        state = imReorderFirstPage(state, input(speaking: both,
                                                nowMS: base.nowMS + IMPromoteAfterMS))
        let promoted = ["u9", "u10"].filter { firstPage(state).contains($0) }
        XCTAssertEqual(promoted.count, 1, "一轮只许换一个")
    }

    func testPinnedIsNeverEvicted() {
        let base = settle()
        // u1 是最久没发言的那个，不钉的话第一个被换。
        var state = imReorderFirstPage(
            base.state, input(speaking: ["u10"], pinned: "u1", nowMS: base.nowMS))
        state = imReorderFirstPage(
            state, input(speaking: ["u10"], pinned: "u1", nowMS: base.nowMS + IMPromoteAfterMS))
        XCTAssertTrue(firstPage(state).contains("u1"))
    }

    // MARK: - 成员进出

    func testLeavingShiftsOthersForward() {
        let base = settle()
        let left = names(10).filter { $0 != "u5" }
        let state = imReorderFirstPage(base.state, input(uids: left, nowMS: base.nowMS + 1))
        XCTAssertFalse(state.order.contains("u5"))
        XCTAssertEqual(state.order.count, 9)
    }

    func testNewcomerGoesToTheEnd() {
        let base = settle()
        let state = imReorderFirstPage(
            base.state, input(uids: names(10) + ["zed"], nowMS: base.nowMS + 1))
        XCTAssertEqual(state.order.last, "zed")
    }

    func testBookkeepingIsPrunedWhenSomeoneLeaves() {
        let base = settle()
        var state = imReorderFirstPage(base.state, input(speaking: ["u3"], nowMS: base.nowMS))
        state = imReorderFirstPage(
            state, input(uids: names(10).filter { $0 != "u3" }, nowMS: base.nowMS + 1))
        XCTAssertNil(state.lastSpokeAt["u3"])
        XCTAssertNil(state.enteredAt["u3"])
    }

    // MARK: - 分页算术

    func testPageCount() {
        XCTAssertEqual(imMeetingPageCount(49), 7, "每页都留一格给自己")
        XCTAssertEqual(imMeetingPageCount(8), 1)
        XCTAssertEqual(imMeetingPageCount(0), 1, "一个远端都没有也有第 1 页")
    }

    func testPagedOnlyBeyondOneScreen() {
        XCTAssertFalse(imMeetingPaged(8), "9 人以内和群通话完全一样")
        XCTAssertTrue(imMeetingPaged(9))
    }

    func testLastPageIsNotPadded() {
        XCTAssertEqual(imMeetingPageSlice(names(10), page: 1), ["u9", "u10"])
        XCTAssertEqual(imMeetingPageSlice(names(10), page: 5), [])
    }

    func testClampPage() {
        XCTAssertEqual(imClampPage(6, total: 2), 1)
        XCTAssertEqual(imClampPage(-1, total: 3), 0)
    }

    func testPageLabel() {
        XCTAssertEqual(imMeetingPageLabel(page: 0, total: 7), "1 / 7")
        XCTAssertEqual(imMeetingPageLabel(page: 6, total: 7), "7 / 7")
    }

    func testDemotedPersonRestartsStayClockWhenBack() {
        let base = settle()
        let speaking: Set<String> = ["u10"]
        // u1 最久没说话，被 u10 顶掉。
        var state = imReorderFirstPage(base.state, input(speaking: speaking, nowMS: base.nowMS))
        state = imReorderFirstPage(state, input(speaking: speaking,
                                                nowMS: base.nowMS + IMPromoteAfterMS))
        XCTAssertFalse(firstPage(state).contains("u1"))
        XCTAssertNil(state.enteredAt["u1"])

        // u1 因为有人离开补位回第一页：驻留时刻要从此刻重新起算，
        // 留着旧的那一条的话他会被下一个说话的人立刻再顶掉，位置一闪就没。
        // 走两个人 u1 才从第 10 位补回来（换位是跟第 10 位对调，不是挪一格）。
        let back = base.nowMS + IMPromoteAfterMS + 1
        let fewer = names(10).filter { $0 != "u2" && $0 != "u3" }
        state = imReorderFirstPage(state, input(uids: fewer, nowMS: back))
        XCTAssertTrue(firstPage(state).contains("u1"))
        XCTAssertEqual(state.enteredAt["u1"], back)
    }

    func testPagedGalleryIsAFixedSquare() {
        // 9 格按「格子最大」算在横屏上是 5×2、竖屏上是 2×5；
        // 分页要的是格子位置固定，左滑只换人。
        XCTAssertEqual(imFixedGridDimensions(9), IMGridDimensions(columns: 3, rows: 3))
        XCTAssertNotEqual(imGridDimensions(9, aspect: 2.2), IMGridDimensions(columns: 3, rows: 3))
        // 最后一页不满也按同样的方阵排，格子不放大（§4.1）。
        XCTAssertEqual(imFixedGridDimensions(9).columns, 3)
    }
}
