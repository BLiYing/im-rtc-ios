import Foundation

/*
 宿主告诉 Engine 两件它自己看不见的事：App 前后台、系统网络换了。
 都只影响**信令断了之后下一次重连要等多久**，规则在 `SignalConnection+Nudge.swift`。
 与 Android `setAppForeground` / `notifyNetworkChanged` 同名同义（CLIENT_PARITY `[^netchange]`）。

 **接了 IMCallKit 的宿主不用管**：`IMCallController` 已自动喂前后台与 `NWPathMonitor`。
 都是提示类：没登录时没有连接，什么都不做；`destroy()` 之后空操作。
 */
extension IMCallEngine {
    /// setAppForeground 告知 App 回到前台 / 进了后台。回前台时：正等着重连的立刻连、退避归零；
    /// 连着的发 ping 探 3 秒，没回音立刻重连（后台挂起过，「连着」往往是假的）。
    @objc public func setAppForeground(_ foreground: Bool) {
        guard !(stateQueue.sync { isDestroyed }) else { return }
        currentConnection?.setAppForeground(foreground)
    }

    /// notifyNetworkChanged 告知系统网络换了（Wi-Fi 断开重连换了 IP、Wi-Fi ⇄ 蜂窝）。
    /// 做法同回前台（2026-09-18 真机：Wi-Fi 重连换 IP 后退避在 30 秒一档空等，通话被结束）。
    @objc public func notifyNetworkChanged() {
        guard !(stateQueue.sync { isDestroyed }) else { return }
        currentConnection?.notifyNetworkChanged()
    }
}
