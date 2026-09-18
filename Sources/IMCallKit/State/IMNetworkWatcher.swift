import Foundation
import IMCallEngine
import Network

/**
 盯系统网络，**换了网络**时告诉 Engine（`IMCallEngine.notifyNetworkChanged()`）。

 2026-09-18 20:45 真机 OPPO：Wi-Fi 自己断开重连 1.5 秒换了 IP，信令在退避 30 秒那一档空等，
 服务端 30 秒恢复窗口先到期，通话被结束。Engine 拿到这条信号就退避归零立刻重连
 （连着的先探死活），规则在 Engine 的 `SignalConnection+Nudge.swift`。与 Android `IMNetworkWatcher` 对应。
 */
final class IMNetworkWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.imrtc.kit.network")
    private let tracker = IMPathChangeTracker()

    init(onChanged: @escaping () -> Void) {
        monitor.pathUpdateHandler = { [tracker] path in
            let signature = path.availableInterfaces.map { "\($0.type)/\($0.name)" }.joined(separator: ",")
                + "|" + path.gateways.map { "\($0)" }.joined(separator: ",")
            guard tracker.observe(satisfied: path.status == .satisfied, signature: signature) else { return }
            IMRTCLog.info("[Kit] 系统网络换了 → 通知 Engine 立即重连", ["path": signature])
            onChanged()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/**
 「网络是不是换了」的判定，与 Network 框架无关，单测直接喂。

 NWPath 没有 Android `Network` 那样的句柄，只能看**可用接口 + 网关**这张指纹：

 - 第一次回调是开始监听时的现状，不是变化。
 - 连不上（unsatisfied）时不报：没网可连，报了也是白连。
 - 从连不上恢复到能连，报——中间断过，旧连接大概率已经死了。
 - 一直能连、指纹变了（Wi-Fi ⇄ 蜂窝、换了路由器）报；指纹没变（只是昂贵 / 受限标志变了）不报。

 Wi-Fi 同一个路由器下换了 IP 而中间没断过，指纹不变、这里认不出来——那一种交给心跳兜底。
 回调都在 `IMNetworkWatcher` 的串行队列上，所以不加锁。
 */
final class IMPathChangeTracker {
    private var seen = false
    private var wasSatisfied = false
    private var signature = ""

    /// observe 喂一次路径更新，返回这一次算不算「换了网络」。
    func observe(satisfied: Bool, signature: String) -> Bool {
        defer {
            seen = true
            wasSatisfied = satisfied
            if satisfied { self.signature = signature }
        }
        guard seen, satisfied else { return false }
        return !wasSatisfied || signature != self.signature
    }
}
