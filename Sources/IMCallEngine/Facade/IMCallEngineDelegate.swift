import Foundation

/*
 回调总表（设计文档 §7.5）——**「只引 SDK 自画 UI」这条路的全部内容就是这张表**。

 # 三个硬约束

 1. **事件名三端同名**：这里的每个方法都对应状态机产出的那个 `onXxx`，
    而那些名字与 Web/桌面、与 `docs/conformance` 的向量是同一套。
    改名 = 改四个仓 + 改向量。
 2. **全部 ObjC 可用**（CONVENTIONS §4）：`@objc` 协议、可选方法、
    参数只用桥接友好的类型。首批宿主 IMProgram 是 Objective-C。
 3. **Kit 也只能用这张表**。Kit 不是特权组件，它拿到的信息与宿主完全一致——
    一旦 Kit 需要开私有口子，说明这张表少了一项，**该补表，不是开后门**。

 # 为什么方法全是 optional

 宿主几乎不可能关心全部 24 个回调（只做 1v1 的用不到会议那几条）。
 required 会逼着每个宿主写一堆空实现，那种代码里迟早混进一个「忘了实现」的真 bug。

 # 回调都在主线程

 CONVENTIONS §5：宿主拿到回调就画界面，别让它们自己 hop。
 */
@objc public protocol IMCallEngineDelegate: AnyObject {

    // MARK: - 连接

    /// 信令通道建立。`resumed` 为真表示恢复了旧会话，房间成员关系还在。
    ///
    /// **重连成功也会抛**，不只是首次登录——宿主的「重连中」提示要靠它撤掉。
    @objc optional func callEngine(_ engine: IMCallEngine,
                                   didConnect sessionID: String, resumed: Bool)

    /// 信令通道断开。`willReconnect` 为假时不会再自动回来。
    ///
    /// `code == 4401` 是宿主**唯一需要特殊处理**的一个：去换一枚新的接入票，
    /// 调 `updateToken(_:)`（协议 §1.5）。连续三次失败之后 Engine 会抛
    /// `callEngineDidGetKickedOut` 收手。
    @objc optional func callEngine(_ engine: IMCallEngine,
                                   didDisconnect code: Int, willReconnect: Bool)

    /// 登录态失效：同账号同设备号在别处登录，**或者接入票连续三次换不上**。
    /// 两种情况的处置一样——回登录页。
    @objc optional func callEngineDidGetKickedOut(_ engine: IMCallEngine)

    /// 任意内部错误。错误码表与服务端同一份（`IMErrorCode`）。
    @objc optional func callEngine(_ engine: IMCallEngine, didFailWithError error: NSError)

    // MARK: - 来电与拨出

    /// 收到邀请（被叫侧）。
    @objc optional func callEngine(_ engine: IMCallEngine, didReceiveCall callID: String,
                                   caller: String, mediaType: String, isGroup: Bool)

    /// 通话接通，**主被叫都抛**。此刻 Engine 已自动进房，但**不会自动推流**——
    /// 推不推、推麦克风还是也推摄像头，是界面的决定。
    @objc optional func callEngine(_ engine: IMCallEngine, callDidBegin callID: String,
                                   roomID: String, mediaType: String, isGroup: Bool, role: String)

    /// 通话结束。**所有结束分支的唯一出口**（不变量 I6）。
    ///
    /// `durationSec` 由服务端给，客户端不自己算（不变量 I8）；唯一的例外是
    /// 重连恢复失败时本地合成的那一条 `network`。
    @objc optional func callEngine(_ engine: IMCallEngine, callDidEnd callID: String,
                                   reason: String, durationSec: Int, endedBy: String)

    /// 主叫取消了呼叫。**便利事件，只在 1v1 抛**，随后必有 `callDidEnd`（不变量 I7）。
    @objc optional func callEngine(_ engine: IMCallEngine, callWasCancelledBy uid: String)
    /// 对方拒接。便利事件，只在 1v1 抛。
    @objc optional func callEngine(_ engine: IMCallEngine, callWasRejectedBy uid: String)
    /// 对方忙线。便利事件，只在 1v1 抛。
    @objc optional func callEngine(_ engine: IMCallEngine, calleeIsBusy uid: String)
    /// 对方无应答。便利事件，只在 1v1 抛。
    @objc optional func callEngine(_ engine: IMCallEngine, calleeDidNotAnswer uid: String)

    /// 本账号另一台设备接听/拒绝了这通电话。`action` 是 `"accept"` / `"reject"`。
    @objc optional func callEngine(_ engine: IMCallEngine, callHandledOnOtherDevice callID: String,
                                   action: String)

    // MARK: - 成员

    /// 有人进房。
    @objc optional func callEngine(_ engine: IMCallEngine, userDidEnter uid: String)
    /// 有人离房。
    @objc optional func callEngine(_ engine: IMCallEngine, userDidLeave uid: String)

    /// 群通话里某人接听了（其余人都收到）。
    @objc optional func callEngine(_ engine: IMCallEngine, userDidAccept uid: String)
    /// 群通话里某人拒接了。
    @objc optional func callEngine(_ engine: IMCallEngine, userDidReject uid: String)
    /// 群通话里某人一直没应答。
    @objc optional func callEngine(_ engine: IMCallEngine, userDidNotRespond uid: String)

    /// 某人的麦克风可用性变了。
    ///
    /// **只在变化时抛**：一开始就正常的人不会有这个事件，所以界面的默认值
    /// 必须是「有音频」——默认 false 会让所有人一进来都显示成静音。
    @objc optional func callEngine(_ engine: IMCallEngine, user uid: String,
                                   audioAvailable available: Bool)
    /// 某人的摄像头可用性变了。同上，只在变化时抛。
    @objc optional func callEngine(_ engine: IMCallEngine, user uid: String,
                                   videoAvailable available: Bool)

    // MARK: - 媒体与质量

    /// 主讲人变化。服务端判定并节流（300ms）。
    ///
    /// **这是全量快照不是增量**：不在名单里的人要被清成「没在说话」，
    /// 只加不减的话高亮会一直亮着不灭。数组元素形如 `["uid": ..., "volume": 0~100]`。
    @objc optional func callEngine(_ engine: IMCallEngine,
                                   activeSpeakersDidChange speakers: [[String: Any]])

    /// 各方网络质量。服务端节流 2s。元素形如 `["uid": ..., "level": 0~6]`，0 = 未知。
    @objc optional func callEngine(_ engine: IMCallEngine,
                                   networkQualityDidChange entries: [[String: Any]])

    /// 某人的**第一帧画面真的到了**，UI 用它撤 loading。
    ///
    /// 本地事件，没有对应的信令帧。判据是轨道出数据，不是协商完成——
    /// 提前抛等于让 UI 撤了 loading 去露黑屏。
    @objc optional func callEngine(_ engine: IMCallEngine, didReceiveFirstVideoFrame uid: String,
                                   trackID: String)

    // MARK: - 房间（会议）

    /// 进会议房成功。
    @objc optional func callEngine(_ engine: IMCallEngine, didJoinRoom roomID: String)

    /// 自己离房成功。
    ///
    /// **会议没有 `callDidEnd`**（那是振铃通话的出口），会议界面的收尾只能靠这一条。
    /// 漏订阅它的后果 Web 端实测过：离房其实成功了，界面还挂在那儿。
    @objc optional func callEngine(_ engine: IMCallEngine, didLeaveRoom roomID: String)

    /// 房间被服务端关掉。
    @objc optional func callEngine(_ engine: IMCallEngine, roomDidClose roomID: String,
                                   reason: String)
}
