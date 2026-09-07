import XCTest
@testable import IMCallEngine

/// 接入票到期提醒（`TokenExpiryTimer`）。
///
/// 时钟与排程都注入，把 12 小时的行为在几毫秒内验完——这类东西用真定时器测就只能 sleep，
/// 没人会去跑第二次。
final class TokenExpiryTests: XCTestCase {

    /// 手动推进的假排程：记下每个任务的延迟，由测试决定什么时候点火。
    private final class FakeClock {
        var nowMS: Int64 = 1_757_000_000_000
        private(set) var scheduled: [(delayMS: Int64, fire: () -> Void)] = []
        private(set) var cancelled = 0

        func schedule(_ delayMS: Int64, _ fire: @escaping () -> Void) -> () -> Void {
            scheduled.append((delayMS, fire))
            let index = scheduled.count - 1
            return { [weak self] in
                guard let self, index < self.scheduled.count else { return }
                self.cancelled += 1
            }
        }

        func fireLast() { scheduled.last?.fire() }
    }

    private func makeTimer(leadMS: Int64 = TokenExpiryTimer.defaultLeadMS)
        -> (FakeClock, TokenExpiryTimer, () -> [Int64]) {
        let clock = FakeClock()
        var fired: [Int64] = []
        let timer = TokenExpiryTimer(
            leadMS: leadMS,
            nowMS: { clock.nowMS },
            schedule: { clock.schedule($0, $1) },
            onWillExpire: { fired.append($0) })
        return (clock, timer, { fired })
    }

    func testArmsAtLeadBeforeExpiry() {
        let (clock, timer, fired) = makeTimer()
        let expiresAt = clock.nowMS + 3_600_000
        timer.arm(expiresAtMS: expiresAt)

        XCTAssertEqual(clock.scheduled.count, 1)
        XCTAssertEqual(clock.scheduled[0].delayMS, 3_600_000 - 60_000)
        XCTAssertTrue(timer.isArmed)

        clock.fireLast()
        XCTAssertEqual(fired(), [expiresAt], "触发时要带上到期时刻")
        XCTAssertFalse(timer.isArmed, "触发后应自己卸掉，同一张票只提醒一次")
    }

    /// 服务端说「未知」时不能报错、也不能瞎猜一个时刻——猜错会在票其实还早的时候催换票。
    /// 正确行为是解除武装，退化成被动行为。
    func testUnknownExpiryDisarms() {
        let (clock, timer, fired) = makeTimer()
        timer.arm(expiresAtMS: 0)
        XCTAssertFalse(timer.isArmed)
        timer.arm(expiresAtMS: -1)
        XCTAssertFalse(timer.isArmed)
        XCTAssertTrue(clock.scheduled.isEmpty)
        XCTAssertTrue(fired().isEmpty)
    }

    /// 票只剩 10 秒时**更**需要提醒宿主，不是更不需要。静默跳过会让
    /// 「登录时票就快过期了」这种场景完全失去提前量。
    func testAlreadyInsideLeadWindowFiresImmediately() {
        let (clock, timer, fired) = makeTimer()
        timer.arm(expiresAtMS: clock.nowMS + 10_000)

        XCTAssertEqual(clock.scheduled.count, 1)
        XCTAssertEqual(clock.scheduled[0].delayMS, 0, "延迟要钳到 0，不能排到过去")
        XCTAssertTrue(fired().isEmpty, "哪怕延迟是 0 也必须经过排程，不能同步烧掉")

        clock.fireLast()
        XCTAssertEqual(fired().count, 1)
    }

    func testExpiredTokenStillFiresOnce() {
        let (clock, timer, _) = makeTimer()
        timer.arm(expiresAtMS: clock.nowMS - 60_000)
        XCTAssertEqual(clock.scheduled[0].delayMS, 0)
    }

    func testRearmCancelsPrevious() {
        let (clock, timer, fired) = makeTimer()
        timer.arm(expiresAtMS: clock.nowMS + 3_600_000)
        timer.arm(expiresAtMS: clock.nowMS + 7_200_000)

        XCTAssertEqual(clock.cancelled, 1, "旧定时器没被取消，两张票会各响一次")
        clock.fireLast()
        XCTAssertEqual(fired(), [clock.nowMS + 7_200_000])
    }

    func testDisarmIsIdempotent() {
        let (_, timer, fired) = makeTimer()
        timer.arm(expiresAtMS: 1_757_000_000_000 + 120_000)
        timer.disarm()
        timer.disarm()
        XCTAssertFalse(timer.isArmed)
        XCTAssertTrue(fired().isEmpty)
    }

    func testLeadIsConfigurable() {
        let (clock, timer, _) = makeTimer(leadMS: 5_000)
        timer.arm(expiresAtMS: clock.nowMS + 60_000)
        XCTAssertEqual(clock.scheduled[0].delayMS, 55_000)
    }
}
