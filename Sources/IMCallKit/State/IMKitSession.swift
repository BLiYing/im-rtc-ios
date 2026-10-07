import Foundation
import IMCallEngine

/**
 宿主取回来的一张 RTC 接入票（server `docs/design/KIT_TOKEN_PROVIDER_DESIGN.md`）。
 `expiresAtMS` 不知道就填 0，Engine 会从 `sys.hello.ok` 拿权威值。与 Web / Android 同名同义。
 */
@objc public final class IMKitToken: NSObject {
    @objc public let token: String
    @objc public let expiresAtMS: Int64

    @objc public init(token: String, expiresAtMS: Int64 = 0) {
        self.token = token
        self.expiresAtMS = expiresAtMS
    }
}

/// 「从你的后台取一张 RTC 接入票」：成功回 `token`，失败回 `error`（二者恰好一个非空），任何线程回调都行。
/// 配在 `IMCallKitConfig.tokenProvider`。
public typealias IMTokenProvider = (@escaping (IMKitToken?, Error?) -> Void) -> Void

/// 登不上时给用户的话分两类（设计 §5）：查网络 / 稍后再试。
enum IMKitFailure: Equatable {
    case network
    case service

    var hintKey: String { self == .network ? "hint.serviceUnreachable" : "hint.serviceUnavailable" }
}

/// 会话用到的那一小片 Engine。真实现见 `IMCallController+Session.swift`，单测换假的。
protocol IMSessionEngine: AnyObject {
    /// 结果回到主线程；`nil` = 登上了。
    func sessionLogin(_ token: String, done: @escaping (Error?) -> Void)
    func sessionLogout()
    func sessionUpdateToken(_ token: String, expiresAtMS: Int64)
    func sessionNotifyNetworkChanged()
}

/**
 Kit 取票登录的会话：**Engine 仍是 push**（`updateToken`，RTC_CALL_DESIGN §7.5 不变），**Kit 来 pull**。

 纯逻辑，计时、联网判断、切主线程都注入——`swift test` 直接驱动（`KitSessionTests`）。
 **只在主线程上用**：取票回调由 `mainThread` 切回来。场景与 Web `kitSession.ts`、Android `IMKitSession` 同表。
 */
final class IMKitSession {
    enum Phase: Equatable { case idle, connecting, ready, waiting, halted }

    /// 失败后的退避（设计 §4）：封顶 60 s，不设次数上限，成功即归零。
    static let retryBackoffMS: [Int] = [2_000, 4_000, 8_000, 16_000, 32_000, 60_000]
    /// `ensure` 最多等多久，超时按网络失败算。
    static let ensureTimeoutMS = 10_000

    typealias Schedule = (_ delayMS: Int, _ task: @escaping () -> Void) -> () -> Void

    private(set) var phase: Phase = .idle

    private weak var engine: IMSessionEngine?
    private let provider: IMTokenProvider
    private let schedule: Schedule
    private let isOnline: () -> Bool
    private let mainThread: (@escaping () -> Void) -> Void

    /// 代际：每轮尝试、每次停止都换代，迟到的回调认得出自己作废了。
    private var generation = 0
    private var failures = 0
    /// 顶号 / 配置被拒：不自动重试，直到下一次登录成功或重新启动。
    private var haltedByKick = false
    private var connected = false
    private var cancelRetry: (() -> Void)?
    private var attemptWaiters: [Waiter] = []
    private var reconnectWaiters: [Waiter] = []

    init(engine: IMSessionEngine, provider: @escaping IMTokenProvider, schedule: @escaping Schedule,
         isOnline: @escaping () -> Bool, mainThread: @escaping (@escaping () -> Void) -> Void) {
        self.engine = engine
        self.provider = provider
        self.schedule = schedule
        self.isOnline = isOnline
        self.mainThread = mainThread
    }

    func start() {
        guard phase == .idle else { return }
        attempt()
    }

    /// 在途的取票 / 登录回来一律作废，等待者按失败结掉，Engine 登出。
    func stop() {
        guard phase != .idle else { return }
        generation += 1
        clearRetry()
        phase = .idle
        connected = false
        haltedByKick = false
        failures = 0
        settle(\.attemptWaiters, .service)
        settle(\.reconnectWaiters, .service)
        engine?.sessionLogout()
    }

    /// 确保已登录：回 `nil` = 可以用了，否则是失败类别。**同一时刻只有一轮尝试**，多处调用共用它。
    func ensure(_ done: @escaping (IMKitFailure?) -> Void) {
        switch phase {
        case .idle:
            done(.service)
        case .ready:
            if connected { done(nil); return }
            // 登上过、正在重连：叫 Engine 别按退避等了，立刻连，然后等 didConnect。
            engine?.sessionNotifyNetworkChanged()
            wait(on: \.reconnectWaiters, done)
        case .connecting:
            wait(on: \.attemptWaiters, done)
        case .waiting, .halted:
            // halted 也试：这是用户亲手点的，代价是一次请求（设计 §4）。
            // 先排队再尝试：取票与登录都同步回来时，这一轮会在 attempt() 里就结掉。
            wait(on: \.attemptWaiters, done)
            attempt()
        }
    }

    func onConnected() {
        connected = true
        if phase == .ready { settle(\.reconnectWaiters, nil) }
    }

    func onDisconnected() {
        connected = false
    }

    func onKickedOut(_ reason: IMKickedOutReason) {
        connected = false
        guard phase != .idle else { return }
        if reason == .authExpired {
            // 票的问题：取一张新票重登。Engine 已经放弃这条连接，先登出再来。
            IMRTCLog.info("[Kit] 票失效被踢，重新取票登录")
            haltedByKick = false
            engine?.sessionLogout()
            attempt()
            return
        }
        // 顶号该回登录页、配置错了重试也没用——都不自动重来（宿主照常收到 wasKickedOutFor）。
        IMRTCLog.warn("[Kit] 被踢下线，不再自动登录", ["reason": String(reason.rawValue)])
        haltedByKick = true
        clearRetry()
        if phase == .ready || phase == .waiting { phase = .halted }
        settle(\.reconnectWaiters, .service)
    }

    /// 票快过期：取新票交给 Engine（下次重连生效）。取不到只记日志，降级成 4401 → authExpired 那条路。
    func onTokenWillExpire() {
        guard phase == .ready else { return }
        let mine = generation
        fetch { [weak self] ticket, error in
            guard let self, mine == self.generation else { return }
            guard let ticket, !ticket.token.isEmpty else {
                IMRTCLog.warn("[Kit] 续票时取票失败", ["err": String(describing: error)])
                return
            }
            self.engine?.sessionUpdateToken(ticket.token, expiresAtMS: ticket.expiresAtMS)
            IMRTCLog.info("[Kit] 已续票")
        }
    }

    /// 网络恢复 / 回到前台：在退避里等着的立刻再试。
    func onNetworkRestored() {
        if phase == .waiting { attempt() }
    }

    private func attempt() {
        clearRetry()
        generation += 1
        phase = .connecting
        let mine = generation
        fetch { [weak self] ticket, error in
            guard let self, mine == self.generation else { return }
            guard let ticket else {
                IMRTCLog.warn("[Kit] 取票失败", ["err": String(describing: error)])
                self.fail(self.isOnline() ? .service : .network)
                return
            }
            guard !ticket.token.isEmpty else {
                IMRTCLog.warn("[Kit] 取票返回空票")
                self.fail(.service)
                return
            }
            self.login(mine, ticket.token)
        }
    }

    private func login(_ mine: Int, _ token: String) {
        // 清掉任何半截状态（上一轮没收干净的连接）；没登录时是空操作。
        engine?.sessionLogout()
        engine?.sessionLogin(token) { [weak self] error in
            guard let self, mine == self.generation else { return }
            if let error {
                imLogRejected("登录", error)
                // Kit 是唯一的重试者：不收的话 Engine 自己的重连会和这里的退避打架。
                self.engine?.sessionLogout()
                self.fail(self.failure(for: error))
                return
            }
            self.phase = .ready
            self.connected = true
            self.failures = 0
            self.haltedByKick = false
            IMRTCLog.info("[Kit] 已登录")
            self.settle(\.attemptWaiters, nil)
        }
    }

    /// 取票的回调可能在任何线程：切回主线程再碰状态。
    private func fetch(_ done: @escaping (IMKitToken?, Error?) -> Void) {
        let hop = mainThread
        provider { ticket, error in hop { done(ticket, error) } }
    }

    /// 连不上 / 超时是网络，其余看设备有没有网。
    private func failure(for error: Error) -> IMKitFailure {
        let code = imRTCErrorCode(error)
        if code == IMErrorCode.networkUnreachable.rawValue || code == IMErrorCode.signalingTimeout.rawValue {
            return .network
        }
        return isOnline() ? .service : .network
    }

    private func fail(_ kind: IMKitFailure) {
        settle(\.attemptWaiters, kind)
        if haltedByKick {
            phase = .halted
            return
        }
        phase = .waiting
        let delay = Self.retryBackoffMS[min(failures, Self.retryBackoffMS.count - 1)]
        failures += 1
        let mine = generation
        cancelRetry = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelRetry = nil
            if mine == self.generation, self.phase == .waiting { self.attempt() }
        }
    }

    private func clearRetry() {
        cancelRetry?()
        cancelRetry = nil
    }

    /// 排进一张等待表，最多等 `ensureTimeoutMS`，超时按网络失败算。
    private func wait(on list: ReferenceWritableKeyPath<IMKitSession, [Waiter]>,
                      _ done: @escaping (IMKitFailure?) -> Void) {
        let waiter = Waiter(done)
        waiter.cancelTimeout = schedule(Self.ensureTimeoutMS) { [weak self, weak waiter] in
            guard let self, let waiter else { return }
            self[keyPath: list].removeAll { $0 === waiter }
            waiter.finish(.network)
        }
        self[keyPath: list].append(waiter)
    }

    /// 先整张摘下来再逐个结：结的时候等待者可能又来 `ensure`（往表里加），不能在遍历中改同一张表。
    private func settle(_ list: ReferenceWritableKeyPath<IMKitSession, [Waiter]>, _ failure: IMKitFailure?) {
        let due = self[keyPath: list]
        self[keyPath: list] = []
        due.forEach { $0.finish(failure) }
    }

    private final class Waiter {
        var cancelTimeout: (() -> Void)?
        private let done: (IMKitFailure?) -> Void
        private var finished = false

        init(_ done: @escaping (IMKitFailure?) -> Void) { self.done = done }

        func finish(_ failure: IMKitFailure?) {
            guard !finished else { return }
            finished = true
            cancelTimeout?()
            done(failure)
        }
    }
}
