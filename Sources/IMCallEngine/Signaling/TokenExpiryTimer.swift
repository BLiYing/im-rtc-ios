import Foundation

/// 被踢下线的原因。
///
/// **不合并成一个「被踢」**：这两种情况宿主的处置完全相反——一个该回登录页，
/// 一个该悄悄换票重来。合并的结果是宿主只能都当登录失效处理，
/// 把本可静默恢复的场景也变成了「请重新登录」。
///
/// `@objc enum` 是因为它要出现在 `@objc` 的 delegate 方法签名里（CONVENTIONS §4）。
@objc public enum IMKickedOutReason: Int, Sendable {
    /// 同账号同设备号在别处登录，或宿主主动吊销（`POST /v1/sessions/revoke`）。
    ///
    /// 两者在线路上都是 `4403` / `1104`，**客户端无从区分**。
    /// 宿主该做的是**回登录页**——换票救不了被封的账号。
    case takenOver = 0

    /// 票不被接受，且连续三次都没换上（`4401` 用尽）。
    ///
    /// 宿主该做的是**重新取一枚票再 login**，不必打扰用户。
    case authExpired = 1
}

/// 接入票到期前的主动换票定时器。
///
/// # 它挡的是什么
///
/// 服务端只在 `sys.hello` 握手时验一次票，之后永不复查。所以票过期**不会**断开已建立的
/// 连接——真正出问题的是**过期之后的第一次重连**：那一次握手撞 `4401`，退避重试三次，
/// 然后 `onKickedOut`，用户被踢回登录页。而重连（切基站、切后台回来、服务端重启）
/// 是必然会发生的，只是不知道什么时候。
///
/// 有了 `sys.hello.ok` 下发的 `token_expires_at_ms`，可以在到期**前**提醒宿主换票，
/// 把那次「必然发生但时间不定」的掉线消灭在发生之前。
///
/// 见 im-rtc-server/docs/design/TOKEN_LIFECYCLE_DESIGN.md §6-①②。
///
/// # 为什么单独一个类型
///
/// 它是纯逻辑（时刻计算 + 一个定时器），注入时钟与排程就能把 12 小时的行为在几毫秒内验完，
/// 不需要真的等。塞进 `SignalConnection` 会让那个类既管连接又管票期，两件事纠缠在一起，
/// 而它已经 400 行、贴着 600 行的体量红线。
final class TokenExpiryTimer {

    /// 到期前多久提醒宿主换票。
    ///
    /// 60 秒的依据是「够宿主打一次自家后台的换票接口，又不至于早到让人莫名其妙」。
    /// 再短的话，一次慢请求就跨过了到期时刻。**五端同一个数。**
    static let defaultLeadMS: Int64 = 60_000

    /// 排一个延时任务，返回一个「取消它」的闭包。可注入以便测试。
    typealias Scheduler = (_ delayMS: Int64, _ fire: @escaping () -> Void) -> () -> Void

    private let leadMS: Int64
    private let nowMS: () -> Int64
    private let schedule: Scheduler
    private let onWillExpire: (Int64) -> Void
    private var cancelCurrent: (() -> Void)?

    var isArmed: Bool { cancelCurrent != nil }

    init(leadMS: Int64 = TokenExpiryTimer.defaultLeadMS,
         nowMS: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         schedule: @escaping Scheduler,
         onWillExpire: @escaping (Int64) -> Void) {
        self.leadMS = leadMS
        self.nowMS = nowMS
        self.schedule = schedule
        self.onWillExpire = onWillExpire
    }

    /// 按新的到期时刻重新武装。
    ///
    /// - `expiresAtMS <= 0` = 服务端说「未知」（协议 §1.2）→ **解除武装，不报错**。
    ///   这条路径退化成没有这个定时器时的被动行为，是刻意降级而不是故障。
    /// - 已经进入提前量窗口（含已过期）→ **立刻触发一次**，而不是静默跳过。
    ///   票只剩 10 秒时更需要提醒宿主，不是更不需要。
    func arm(expiresAtMS: Int64) {
        disarm()
        guard expiresAtMS > 0 else { return }

        let delayMS = max(0, expiresAtMS - leadMS - nowMS())
        // 即使延迟是 0 也走排程，不同步回调：arm 是在握手成功的路径上调的，
        // 同步回调会让宿主的 updateToken 重入到还没走完的连接流程里。
        cancelCurrent = schedule(delayMS) { [weak self] in
            guard let self else { return }
            self.cancelCurrent = nil
            self.onWillExpire(expiresAtMS)
        }
    }

    /// 解除武装。重复调用安全。
    func disarm() {
        cancelCurrent?()
        cancelCurrent = nil
    }
}
