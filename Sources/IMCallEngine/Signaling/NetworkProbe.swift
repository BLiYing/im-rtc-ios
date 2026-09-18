import Foundation

/*
 「连着的那条信令还活不活」：发一个 `sys.ping`，`probeMS` 内收到**任何**下行帧就算活，否则判死。
 回前台、系统网络变了的时候用（见 `SignalConnection+Nudge.swift`）。与 Android `IMNetworkProbe` 同一个数。

 # 为什么要探，而不是等心跳

 心跳要连着 3 个周期（45 秒）收不到东西才判死，而服务端给的恢复窗口只有 30 秒。
 2026-09-18 20:45 真机 OPPO：Wi-Fi 自己断开重连换了 IP，旧 socket 已死但 TCP 不吭声。
 iOS 更常见的是另一种：App 在后台被挂起一阵，回前台时 socket 早被系统或 NAT 掐了，
 本端还报着 `.connected`。

 # 为什么不是见变化就断

 默认网络变化不一定伤到旧连接（蜂窝 → Wi-Fi 时蜂窝还挂一阵、开关 VPN 也报一次），
 回前台更是大多数时候连接好好的。见变化就断会白白掐掉在飞请求；探一下只多等 3 秒。
 */
final class NetworkProbe {
    /// 局域网与 4G 下 pong 都在几百毫秒内回来；3 秒没回就不是慢，是断了。
    static let probeMS = 3_000

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var answered = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// 正在探。已经在探就不再发第二个 ping——网络来回跳时一次只探一个。
    var armed: Bool { timer != nil }

    /// arm 发探测 ping，`probeMS` 后没收到下行就回调 `onDead`。
    ///
    /// 调用方在连接关闭时**必须** `stop()`：否则这一代的判决会落到下一代连接头上。
    func arm(sendPing: () -> Void, onDead: @escaping () -> Void) {
        guard timer == nil else { return }
        answered = false
        sendPing()
        timer = imAfter(.milliseconds(Self.probeMS), on: queue) { [weak self] in
            guard let self else { return }
            self.timer = nil
            if !self.answered { onDead() }
        }
    }

    /// noteFrameReceived 由读循环无差别调用：收到任何帧都算活，不必是那条 pong。
    func noteFrameReceived() {
        answered = true
    }

    /// stop 撤掉探测。幂等。
    func stop() {
        timer?.cancel()
        timer = nil
    }
}
