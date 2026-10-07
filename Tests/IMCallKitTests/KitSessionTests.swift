import XCTest
import IMCallEngine
@testable import IMCallKit

/// Kit 取票登录的会话（server `docs/design/KIT_TOKEN_PROVIDER_DESIGN.md` §4）。
/// 计时、联网判断、切主线程都是注入的；场景与 Web `kitSession.test.ts`、Android `KitSessionTest` 一一对应。
final class KitSessionTests: XCTestCase {
    /// 手动推进的时钟：`advance(ms)` 跑掉到点的任务。
    private final class Clock {
        var now = 0
        private var tasks: [(at: Int, task: () -> Void, live: Box)] = []
        final class Box { var live = true }

        func schedule(_ delayMS: Int, _ task: @escaping () -> Void) -> () -> Void {
            let box = Box()
            tasks.append((now + delayMS, task, box))
            return { box.live = false }
        }

        func pending() -> [Int] { tasks.filter { $0.live.live && $0.at > now }.map { $0.at - now } }

        func advance(_ ms: Int) {
            now += ms
            for entry in tasks where entry.live.live && entry.at <= now {
                entry.live.live = false
                entry.task()
            }
        }
    }

    private final class FakeEngine: IMSessionEngine {
        var log: [String] = []
        var loginError: Error?
        var holdLogin = false
        var held: ((Error?) -> Void)?

        func sessionLogin(_ token: String, done: @escaping (Error?) -> Void) {
            log.append("login:\(token)")
            if holdLogin { held = done } else { done(loginError) }
        }

        func sessionLogout() { log.append("logout") }
        func sessionUpdateToken(_ token: String, expiresAtMS: Int64) { log.append("update:\(token):\(expiresAtMS)") }
        func sessionNotifyNetworkChanged() { log.append("nudge") }
        var logins: [String] { log.filter { $0.hasPrefix("login:") } }
    }

    private final class Rig {
        let engine = FakeEngine()
        let clock = Clock()
        var online = true
        var calls = 0
        /// 默认同步给票；测试可换成失败 / 挂起。
        lazy var next: (@escaping (IMKitToken?, Error?) -> Void) -> Void = { [unowned self] done in
            done(IMKitToken(token: "t\(self.calls)"), nil)
        }
        lazy var session = IMKitSession(
            engine: engine,
            provider: { [unowned self] done in self.calls += 1; self.next(done) },
            schedule: { [unowned self] delay, task in self.clock.schedule(delay, task) },
            isOnline: { [unowned self] in self.online },
            mainThread: { $0() })

        /// 同步跑完的 ensure 结果；`done == false` 表示还在等。
        func ensure() -> (done: Bool, failure: IMKitFailure?) {
            var result: (done: Bool, failure: IMKitFailure?) = (false, nil)
            session.ensure { result = (true, $0) }
            return result
        }
    }

    private struct Boom: Error {}
    private let fail: (@escaping (IMKitToken?, Error?) -> Void) -> Void = { $0(nil, Boom()) }
    private func rtcError(_ code: IMErrorCode) -> Error { NSError(domain: IMRTCErrorDomain, code: code.rawValue) }

    func testStartLogsInAndEnsureIsImmediate() {
        let r = Rig()
        r.session.start()
        XCTAssertEqual(r.engine.logins, ["login:t1"])
        XCTAssertEqual(r.session.phase, .ready)
        let res = r.ensure()
        XCTAssertTrue(res.done)
        XCTAssertNil(res.failure)
    }

    func testFetchFailureBacksOffThenResets() {
        let r = Rig()
        r.next = fail
        r.session.start()
        XCTAssertEqual(r.session.phase, .waiting)
        XCTAssertEqual(r.clock.pending(), [2_000])
        r.clock.advance(2_000)
        XCTAssertEqual(r.calls, 2)
        XCTAssertEqual(r.clock.pending(), [4_000])
        r.next = { $0(IMKitToken(token: "ok"), nil) }
        r.clock.advance(4_000)
        XCTAssertEqual(r.engine.logins, ["login:ok"])
        XCTAssertEqual(r.session.phase, .ready)
        XCTAssertEqual(r.clock.pending(), [])
    }

    func testBackoffCapsAtSixtySeconds() {
        let r = Rig()
        r.next = fail
        r.session.start()
        IMKitSession.retryBackoffMS.forEach { r.clock.advance($0) }
        XCTAssertEqual(r.clock.pending(), [60_000])
    }

    func testEnsureWhileWaitingRetriesNow() {
        let r = Rig()
        r.next = fail
        r.session.start()
        r.next = { $0(IMKitToken(token: "now"), nil) }
        let res = r.ensure()
        XCTAssertTrue(res.done)
        XCTAssertNil(res.failure)
        XCTAssertEqual(r.engine.logins, ["login:now"])
    }

    func testConcurrentEnsureSharesOneAttempt() {
        let r = Rig()
        r.engine.holdLogin = true
        r.session.start()
        var results: [IMKitFailure?] = []
        r.session.ensure { results.append($0) }
        r.session.ensure { results.append($0) }
        r.engine.held?(nil)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.compactMap { $0 }, [])
        XCTAssertEqual(r.calls, 1)
    }

    func testFailureKinds() {
        let r1 = Rig()
        r1.engine.loginError = rtcError(.networkUnreachable)
        r1.session.start()
        XCTAssertEqual(r1.ensure().failure, .network)

        let r2 = Rig()
        r2.next = fail
        r2.session.start()
        XCTAssertEqual(r2.ensure().failure, .service)
        r2.online = false
        XCTAssertEqual(r2.ensure().failure, .network)
    }

    func testLoginFailureLogsOutFirst() {
        let r = Rig()
        r.engine.loginError = rtcError(.tokenInvalid)
        r.session.start()
        XCTAssertEqual(r.engine.log, ["logout", "login:t1", "logout"])
    }

    func testLateTokenAfterStopIsDropped() {
        let r = Rig()
        var late: ((IMKitToken?, Error?) -> Void)?
        r.next = { late = $0 }
        r.session.start()
        var waiting: (done: Bool, failure: IMKitFailure?) = (false, nil)
        r.session.ensure { waiting = (true, $0) }
        r.session.stop()
        XCTAssertTrue(waiting.done)
        XCTAssertEqual(waiting.failure, .service)
        late?(IMKitToken(token: "late"), nil)
        XCTAssertEqual(r.engine.logins, [])
        XCTAssertEqual(r.session.phase, .idle)
    }

    func testNetworkRestoredRetriesNow() {
        let r = Rig()
        r.next = fail
        r.session.start()
        r.session.onNetworkRestored()
        XCTAssertEqual(r.calls, 2)
    }

    func testTokenWillExpireRenews() {
        let r = Rig()
        r.session.start()
        r.next = { $0(IMKitToken(token: "fresh", expiresAtMS: 99), nil) }
        r.session.onTokenWillExpire()
        XCTAssertTrue(r.engine.log.contains("update:fresh:99"))
    }

    func testAuthExpiredRelogs() {
        let r = Rig()
        r.session.start()
        r.session.onKickedOut(.authExpired)
        XCTAssertEqual(r.engine.logins, ["login:t1", "login:t2"])
        XCTAssertEqual(r.session.phase, .ready)
    }

    func testTakenOverHaltsButUserTapStillTries() {
        let r = Rig()
        r.session.start()
        r.session.onKickedOut(.takenOver)
        XCTAssertEqual(r.session.phase, .halted)
        XCTAssertEqual(r.clock.pending(), [])
        r.next = fail
        XCTAssertEqual(r.ensure().failure, .service)
        XCTAssertEqual(r.session.phase, .halted)
        XCTAssertEqual(r.clock.pending(), [])
    }

    func testReconnectingNudgesAndWaitsForConnect() {
        let r = Rig()
        r.session.start()
        r.session.onDisconnected()
        var waiting: (done: Bool, failure: IMKitFailure?) = (false, nil)
        r.session.ensure { waiting = (true, $0) }
        XCTAssertTrue(r.engine.log.contains("nudge"))
        r.session.onConnected()
        XCTAssertTrue(waiting.done)
        XCTAssertNil(waiting.failure)
    }

    func testEnsureTimesOutAsNetwork() {
        let r = Rig()
        r.session.start()
        r.session.onDisconnected()
        var waiting: (done: Bool, failure: IMKitFailure?) = (false, nil)
        r.session.ensure { waiting = (true, $0) }
        r.clock.advance(IMKitSession.ensureTimeoutMS)
        XCTAssertTrue(waiting.done)
        XCTAssertEqual(waiting.failure, .network)
    }

    func testEnsureBeforeStartFails() {
        let r = Rig()
        XCTAssertEqual(r.ensure().failure, .service)
    }
}
