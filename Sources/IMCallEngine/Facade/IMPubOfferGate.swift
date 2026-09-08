import Foundation

/**
 上行协商闸门：**一条 pub PC 上同一时刻只许一个 offer 在飞**。

 # 不加会怎样

 发布 audio 与 video 两条轨道 → 两次 `room.publish.ok` → 状态机连着吐两帧
 `room.offer{pc:"pub"}`。两个 offer 一起在飞时：

 1. offer#1 `setLocalDescription` → 状态 `have-local-offer`
 2. offer#2 又 `setLocalDescription` → 覆盖掉 offer#1
 3. answer#1 回来 `setRemoteDescription` → 状态回到 `stable`
 4. answer#2 回来 `setRemoteDescription` → **`Called in wrong state: stable`**

 真机 2026-09-08 的 iOS 日志里就是这一串，紧跟着一条 `error code=1501 internal`。
 那一次自愈了，但 Android 上同一个缺陷的后果是**上行再也协商不出去**
 （见 `im-rtc-android` 的 `IMNegotiationGate`）。

 # 为什么「帧泵是串行的」挡不住

 `IMFrameLoop` 是 actor，发帧确实一条条来。可 `connection.request` 只等到
 `room.offer.ok`，**answer 是随后一条独立的 `room.answer` 帧**——
 offer → answer 这一整个回合根本不在 actor 的串行范围内。

 # 与 Android 那份的两处不同

 - **没有锁**：这里只被 `IMFrameLoop` 这一个 actor 碰，串行是编译器保证的；
   Android 那份要挨三个线程，所以必须自己上锁。
 - **没有 `pendingIceRestart`**：iOS 把「下一个 offer 要不要重启 ICE」放在
   `IMWebRTCAdapter.pubICERestartPending` 上，由 `createPubOffer` 消费——
   排队不会把它弄丢，补发那一轮自然会带上。**别照抄 Android 那一位**。

 # 每一个终局都要放闸

 不只是成功那条路：发帧失败、通话结束、会话恢复换了连接，都得放。
 少放一处就是**永久卡死**，而且一条错误都没有，只表现为「对端再也看不到我」。
 */
struct IMPubOfferGate {
    /// 有一个 offer 已经发出去、还在等它的 answer。
    private(set) var isNegotiating = false
    /// 「刚才想发但那时有 offer 在飞」，等这一轮收工要补一次。
    private var pending = false

    /// 申请发一个 offer。`false` = 这一轮不发（已记下待补）。
    mutating func begin() -> Bool {
        if isNegotiating {
            pending = true
            return false
        }
        isNegotiating = true
        return true
    }

    /// 这一轮**成功**收工（answer 落地）。返回是否还欠一个 offer。
    mutating func finish() -> Bool {
        isNegotiating = false
        let owed = pending
        pending = false
        return owed
    }

    /**
     这一轮**失败**收场（帧没发出去、或 answer 应用失败）。

     与 `finish()` 的差别只有一处：**不补排队的那一个**。这一轮都失败了，
     立刻再发一个多半是同样的下场，交给上层的重试节奏去驱动，别在这里自旋。
     */
    mutating func abort() {
        isNegotiating = false
    }

    /**
     换了一条连接 / 通话结束：把在飞状态清掉。

     **换连接之后旧 offer 的 answer 永远不会回来了**——它是从旧 socket 上发出去的。
     不清的话闸门一直关着，恢复后的重新协商只会排队，那条 PC 就此永久沉默。
     Android 上真机撞到过这一幕（Wi-Fi 关掉再打开，上行再也没协商过一次）。
     */
    mutating func reset() {
        isNegotiating = false
        pending = false
    }
}
