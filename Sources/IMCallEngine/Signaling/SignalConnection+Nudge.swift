import Foundation

/*
 回前台、系统网络变了：**不再按退避白等**（2026-09-18，与 Android 对齐，CLIENT_PARITY `[^netchange]`）。

 20:45 真机 OPPO：Wi-Fi 自己断开重连换了 IP，信令退避正在 30 秒那一档空等，服务端 30 秒
 恢复窗口先到期，通话被结束。iOS 多一种更常见的：App 在后台挂起一阵，回前台时 socket 早死了，
 或者退避已经退到 30 秒一档——用户正看着「正在重连」。

 # 三种处境三种做法（回前台与网络变化同一套）

 - **正等着重连**：撤掉定时器，退避归零，立刻连。
 - **连着**：发 ping 探 3 秒（`NetworkProbe`），没回音就判死、立刻重连；有回音什么都不动。
 - **正在连**：让这次跑完（成了最好）；失败了不走退避，立刻再连（`networkChangePending`）。

 两次「立刻重连」之间至少隔 `nudgeMinGapMS`：网络来回跳时不刷出重连风暴。

 # 与 Android 的一处差异

 Android 回前台**只管「正等着重连」那一种**，iOS 回前台三种都管——Android 后台进程还活着、
 心跳照跑；iOS 后台被挂起，心跳定时器停摆，回来时「连着」往往是假的。
 Android 的「后台短命连接封顶 3 秒」（ColorOS 掐后台 socket）iOS 用不上：挂起的 App 不重连。

 全部方法只在 `queue` 上跑。
 */
extension IMSignalConnection {
    /// 两次「立刻重连」之间至少隔这么久。与 Android `IMReconnectTimer` 同一个数。
    static let nudgeMinGapMS = 2_000

    /// setAppForeground 告知 App 前后台切换。回前台按「三种处境」处理，进后台只记一行。
    public func setAppForeground(_ foreground: Bool) {
        queue.async {
            IMRTCLog.info("App 切到\(foreground ? "前台" : "后台")", ["state": self.state.rawValue])
            if foreground { self.nudge(rule: "回前台") }
        }
    }

    /// notifyNetworkChanged 告知系统网络换了（Wi-Fi 重连换 IP、Wi-Fi ⇄ 蜂窝）。
    public func notifyNetworkChanged() {
        queue.async {
            IMRTCLog.info("系统网络变了", ["state": self.state.rawValue,
                                       "waiting": String(self.reconnectTimer != nil)])
            self.nudge(rule: "网络变化")
        }
    }

    private func nudge(rule: String) {
        switch state {
        case .idle, .closed:
            return
        case .connected:
            networkProbe.arm(sendPing: { sendPing() }) { [weak self] in
                guard let self, self.state == .connected else { return }
                IMRTCLog.warn("\(rule)后 \(NetworkProbe.probeMS)ms 没收到下行，旧连接判死")
                self.networkChangePending = true
                self.socket?.close(code: IMCloseCode.goingAway, reason: "probe timeout")
            }
        case .connecting, .reconnecting:
            if reconnectTimer != nil {
                reconnectRightAway(rule: "\(rule)立即重连")
            } else {
                networkChangePending = true
            }
        }
    }

    /// reconnectRightAway 退避归零、立刻连；离上一次不足 `nudgeMinGapMS` 就补足间隔。
    func reconnectRightAway(rule: String) {
        networkChangePending = false
        reconnectTimer?.cancel()
        reconnectTimer = nil
        reconnectAttempt = 0
        let now = DispatchTime.now().uptimeNanoseconds
        let gapNS = UInt64(Self.nudgeMinGapMS) * 1_000_000
        let elapsed = lastNudgeReconnectNS == 0 ? gapNS : now &- lastNudgeReconnectNS
        let waitMS = elapsed >= gapNS ? 0 : Int((gapNS - elapsed) / 1_000_000)
        IMRTCLog.info("计划重连", ["attempt": "0", "delay_ms": String(waitMS), "rule": rule])
        let go = { [weak self] in
            guard let self, self.state == .reconnecting || self.state == .connecting else { return }
            self.reconnectTimer = nil
            self.lastNudgeReconnectNS = DispatchTime.now().uptimeNanoseconds
            Task { [weak self] in _ = try? await self?.connect() }
        }
        if waitMS == 0 {
            go()
        } else {
            reconnectTimer = imAfter(.milliseconds(waitMS), on: queue, go)
        }
    }
}
