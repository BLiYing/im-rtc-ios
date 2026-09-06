import Foundation

/*
 媒体适配器：**Engine 里唯一碰 WebRTC 的地方**（CONVENTIONS §1）。

 # 为什么它只是一个协议

 libwebrtc 是个 iOS-only 的预编译二进制包。一旦 `IMCallEngine` 直接依赖它，
 「跑一次单测」就变成「起模拟器 + 下载几百 MB」——而本仓最需要频繁回归的
 恰恰是不碰媒体的那一半（协议编解码、三个状态机、四仓共用的一致性向量）。

 所以媒体在 Engine 里只以协议的形式存在，真实现放随后的 iOS-only target
 （`IMCallEngineWebRTC`）。这与 Web 端「engine 必须能在无 DOM 的 Node 里构造」
 是同一条约束，理由也一样。

 # 门面没有适配器也能用

 「只要信令、UI 自己画」的宿主可以完全不给适配器：登录、振铃、成员进出、
 静音通知这些**一个都不少**，只有推流与画面挂载会以
 `mediaUnavailable` 失败。这不是降级，是产品的两种集成方式之一。
 */

/// 两条 PeerConnection 的角色。**pub 的 offerer 恒为本端，sub 恒为服务端**（协议 §3.3）。
@objc public enum IMPCRole: Int, Sendable {
    case pub
    case sub

    /// wireValue 是线路上的写法。
    public var wireValue: String { self == .pub ? "pub" : "sub" }
}

/// 一条本端轨道。
public struct IMLocalTrackInfo: Sendable {
    /**
     cid **等于本地轨道的 id**。

     msid 的第二段就是它，服务端靠它认领 m-line（协议 §3.2）。所以顺序是
     **先拿轨道、再拿 cid、最后才发 `room.publish`**——不能先想一个 cid 再去取轨道。
     */
    public let cid: String
    /// `"audio"` / `"video"`。
    public let kind: String
    /// `"microphone"` / `"camera"`。
    public let source: String

    public init(cid: String, kind: String, source: String) {
        self.cid = cid
        self.kind = kind
        self.source = source
    }
}

/// 一个 ICE 候选（线路形状）。
public struct IMICECandidate: Sendable {
    public let candidate: String
    public let sdpMid: String
    public let sdpMLineIndex: Int

    public init(candidate: String, sdpMid: String, sdpMLineIndex: Int) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

/// 媒体层回给 Engine 的出口。
public struct IMMediaAdapterEvents: Sendable {
    /// 本端收集到一个候选，Engine 要把它发成 `room.ice_candidate`。
    public var onLocalCandidate: (@Sendable (IMPCRole, IMICECandidate) -> Void)?
    /// 收到一条下行轨道。`trackID` 就是协议里的 track_id（msid 第二段）。
    public var onRemoteTrack: (@Sendable (String) -> Void)?
    /// 某条 PC 的连接状态变了。Engine 据此判断「媒体就绪」。
    public var onConnectionStateChange: (@Sendable (IMPCRole, String) -> Void)?
    /// 某条下行轨道**真的出数据了**（第一帧）。
    ///
    /// **判据必须是「出数据」而不是「协商完成」**：协商完成时远端轨道还是静的，
    /// 那一刻让 UI 撤 loading 就是露黑屏。Web 端为此改过一次（用轨道的 `unmute`）。
    public var onFirstVideoFrame: (@Sendable (String) -> Void)?

    public init() {}
}

/// 媒体层的契约。**一个方法都不许让状态机看见**——状态机是纯的。
public protocol IMMediaAdapter: AnyObject, Sendable {
    /// open 建立两条 PeerConnection。**每个参与者最多两条**（CONVENTIONS §8）。
    func open(_ events: IMMediaAdapterEvents)

    /// acquireMicrophone 拿麦克风轨道挂到 pub PC 上，返回它的 cid。
    func acquireMicrophone() async throws -> IMLocalTrackInfo

    /**
     probeMicrophone **只探一下麦克风权限**，不挂到任何 PC 上（四端同名，Web 的 `probeMicrophone`）。

     权限申请的时机规则（交互稿 §01）：主叫在发 `call.invite` **之前**、被叫在发 `call.accept`
     **之前**就得知道麦克风拿不拿得到——拿不到就不该去响别人的铃。而 `acquireMicrophone`
     要等房间开了（pub PC 存在）才能调，那时早就过了该问的时刻。
     被拒抛 `2001 device_permission_denied`，没设备抛 `2002 device_not_found`。
     */
    func probeMicrophone() async throws

    /**
     startLocalPreview 只**起采集**，不发布（设计文档 §7.5 的 `startLocalPreview`）。

     拨出中还没有房间，推流无从谈起，但界面这时就该让人看见自己
     （草图 §03-E）。所以「采集」与「发布」必须是两件事：
     这个方法起摄像头并返回 cid，随后的 `acquireCamera` **复用同一条轨道**
     再挂到 pub 上——否则会把摄像头开两次。
     */
    func startLocalPreview() async throws -> IMLocalTrackInfo

    /// acquireCamera 拿摄像头轨道挂到 pub PC 上，返回它的 cid。
    /// 已经在预览的话**复用那条轨道**，不重开摄像头。
    func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo

    /// createPubOffer 生成上行 offer。
    func createPubOffer() async throws -> String

    /**
     restartPubICE 让**下一个**上行 offer 带上 ICE restart（换一对新 ufrag/pwd 重新打洞）。

     `pub` 那条 PC 的 offerer 恒为本端（协议 §3.3），所以它 `failed` 了只能自己救；
     `sub` 那条由服务端救（`sfu.Peer.RestartSubICE`）——**各自重启自己 offer 的那条**，
     两边都不需要新的协议帧，也不会 glare。

     做成「置一个位、下一个 offer 生效」而不是「立刻发一个 offer」：
     发帧是 Engine 的事，媒体层不认识信令。
     */
    func restartPubICE()

    /// applyPubAnswer 应用服务端对上行 offer 的应答。
    func applyPubAnswer(_ sdp: String) async throws

    /// answerSubOffer 应答服务端下发的下行 offer。
    func answerSubOffer(_ sdp: String) async throws -> String

    /// addRemoteCandidate 加一个远端候选。**乱序到达是常态**，实现必须容忍（协议 §3.3）。
    func addRemoteCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async throws

    /// setMuted 开关本端某条轨道。
    ///
    /// **这不是 unpublish**：轨道与协商都保留，只是停止发包。
    /// 反复开关摄像头走 unpublish 会触发重协商风暴（协议 §3.2）。
    func setMuted(_ cid: String, _ muted: Bool)

    /// setSpeakerOn 切换扬声器 / 听筒。**只改路由不改采集**，通话不中断。
    func setSpeakerOn(_ on: Bool)

    /**
     switchCamera 前后摄像头翻转。

     **不重新协商**：换的是同一条轨道的采集源，`track_id` / `cid` 一个都不变，
     服务端与对端都不需要知道这件事。翻转失败（只有一个摄像头、被别的程序占用）
     就保持原样，别把通话弄断。
    */
    func switchCamera() async

    /**
     claimRemoteTracks 告诉媒体层「哪条 track_id 属于哪个 uid」（`[track_id: uid]`）。

     **这一步不能省。** 媒体层拿到下行轨道时只知道 track_id（msid 第二段），
     而归属写在信令帧 `room.track_published` 里，两者**谁先到都可能**。
     少了认领这一步，媒体层就只能把 track_id 当 uid 用，
     而挂载侧 `attachRemoteView` 传的是真 uid——两把钥匙对不上，
     协商全通、首帧照抛，**但一格画面都不出来**。
     （Web 端的 `MediaBridge.claim` 是同一件事。）

     实现要幂等：每次状态机推进都会调它一次。
    */
    func claimRemoteTracks(_ owners: [String: String])

    /// attachRemoteView 把某个 uid 的远端画面挂到一个视图上；传 nil 卸载。
    func attachRemoteView(_ uid: String, _ view: AnyObject?)

    /// attachLocalView 把本端某条轨道挂到视图上做预览；传 nil 卸载。
    func attachLocalView(_ cid: String, _ view: AnyObject?)

    /// close 关掉两条 PC 并停掉所有本端轨道。
    func close()
}
