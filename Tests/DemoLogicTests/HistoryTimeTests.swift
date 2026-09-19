import XCTest

/// 通话记录时间文案：四端共用同一张用例表（今天 / 昨天 / 今年更早 / 往年 / 跨零点 / 时钟偏差）。
/// `HistoryTime.swift` 是指向 Demo 工程里那份源文件的符号链接——Demo 没有单测 target，这是唯一不复制代码的接法。
final class HistoryTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Int64 {
        let date = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func fmt(_ started: Int64, _ now: Int64) -> String {
        formatCallTime(startedAtMS: started, nowMS: now, calendar: calendar) { date in
            let c = self.calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", c.hour!, c.minute!)
        }
    }

    private lazy var now = at(2026, 9, 19, 11, 40)

    func testTodayShowsHourMinute() { XCTAssertEqual(fmt(at(2026, 9, 19, 11, 35), now), "11:35") }
    func testMidnightSharpIsToday() { XCTAssertEqual(fmt(at(2026, 9, 19, 0, 0), now), "00:00") }
    func testYesterday() { XCTAssertEqual(fmt(at(2026, 9, 18, 23, 11), now), "昨天 23:11") }
    func testAcrossMidnightIsByCalendarDayNot24h() {
        XCTAssertEqual(fmt(at(2026, 9, 18, 23, 50), at(2026, 9, 19, 0, 10)), "昨天 23:50")
    }
    func testEarlierThisYearShowsMonthDay() { XCTAssertEqual(fmt(at(2026, 9, 15, 18, 17), now), "9月15日 18:17") }
    func testPreviousYearShowsYear() { XCTAssertEqual(fmt(at(2025, 12, 31, 9, 5), now), "2025年12月31日 09:05") }
    func testNewYearsDayLooksBackToYesterday() {
        XCTAssertEqual(fmt(at(2025, 12, 31, 23, 59), at(2026, 1, 1, 8, 0)), "昨天 23:59")
    }
    func testFutureTimestampCountsAsToday() { XCTAssertEqual(fmt(at(2026, 9, 19, 11, 50), now), "11:50") }
}
