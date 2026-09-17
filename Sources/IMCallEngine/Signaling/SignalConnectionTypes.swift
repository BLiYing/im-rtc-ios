import Foundation

/*
 信令连接层对外的几个类型：握手结果、连接状态、回调表、构造参数。
 从 `SignalConnection.swift` 拆出来（体量红线，CONVENTIONS §2）——它们是连接层的**契约**，
 与连接的实现（握手、重连、配对）分开放，读契约不必翻实现。
 */

/// 握手成功后的服务端信息。
public struct IMHelloOK: Sendable {
    public let uid: String
    public let deviceID: String
    public let sessionID: String
    public let resumed: Bool
    public let pingIntervalSec: Int
    /// 本次握手用的那张票的到期时刻（Unix 毫秒）。**0 = 未知**。
    public let tokenExpiresAtMS: Int64
    public let maxFrameBytes: Int
    public let maxCallees: Int
    public let maxRoomParticipants: Int
    public let ringTimeoutSecDefault: Int
}

/// 连接状态。
public enum IMConnectionState: String, Sendable {
    case idle, connecting, connected, reconnecting, closed
}

/// 连接层对外的回调。**全部在信令队列上调用**。
public struct IMConnectionEvents {
    /**
     握手完成——**每一次**，包括自动重连那些。

     门面必须接住它，并把 `sys.hello.ok` 喂给状态机。**不能只在 `login()` 里喂一遍**：
     重连是连接层自己发起的，那次握手的结果只从这里出来。漏掉的后果不是「少一个事件」，
     而是重连之后状态机根本不知道自己重连了——`resumed == false` 时房间与通话不归零
     （服务端那边早就没了，之后每一帧都发向一个不存在的房间）、`resumed == true` 时
     攒下的意图不重放，宿主也永远收不到第二次 `onConnected`。

     （Web 端就是这么漏的，症状是服务端重启后换票重连其实成功了，界面却一直停在
     「重连中」。见 im-rtc-web 的 `connectionFactory.ts`。）
     */
    public var onConnected: ((IMHelloOK) -> Void)?
    /// 收到服务端主动推送的事件（req_id 为空的帧）。
    public var onEvent: ((String, [String: IMJSON]) -> Void)?
    /// 连接断开。willReconnect=false 时不会再自动回来。
    public var onDisconnected: ((Int, Bool) -> Void)?
    /// 被踢下线，**不会自动重连**。
    ///
    /// `reason` 决定宿主该做什么，两者处置相反——合并成一个「被踢」的话，
    /// 宿主只能都当登录失效处理，把本可静默恢复的场景也变成「请重新登录」。
    public var onKickedOut: ((IMKickedOutReason) -> Void)?
    /**
     断得太久了，**服务端那一侧的会话已经不可能再恢复**（§1.4 的恢复窗口过了）。

     与「重连上了但 `resumed == false`」是同一件事，只是**不必等重连成功**——
     网络一直不回来的话那一刻永远不会到。少了它，界面就永远停在「正在重连」、
     连挂断都点不动（挂断只产出一帧发不出去的 `call.hangup`，本地状态一动不动，
     这是 §4.2 铁律 1 的直接后果）。真机 2026-09-08 的 iOS carol 就是这一幕。
     */
    public var onSessionUnrecoverable: (() -> Void)?
    /// 票快到期了，宿主该去取新票并 `updateToken`。见 `TokenExpiryTimer`。
    public var onTokenWillExpire: ((Int64) -> Void)?
    /// 内部错误。
    public var onError: ((IMRTCError) -> Void)?

    public init() {}
}

/// 构造参数。带 Factory / random 的都是为了测试可注入。
public struct IMConnectionOptions {
    public var url: URL
    public var token: String
    public var deviceID: String
    public var sdk: String = "ios/\(IMCallEngineVersion)"
    /// 请求超时。协议建议 10 秒（§2.2）。
    public var requestTimeoutMS: Int = 10_000
    public var webSocketFactory: IMWebSocketFactory = imURLSessionWebSocketFactory
    public var random: () -> Double = { Double.random(in: 0..<1) }
    /**
     覆盖「断多久算服务端已经放弃这条会话」的时长（毫秒）。**只为测试可注入。**

     真值是 `3×ping + 30s + 余量`（见 `IMSignalConnection.giveUpDelayMS`），
     默认 80 秒——一条用例不可能真等 80 秒，而这条路**全是时序**，
     不测就等于没写（CONVENTIONS §9 点名的那一类）。
     */
    public var resumeGiveUpDelayMSForTesting: Int?

    public init(url: URL, token: String, deviceID: String) {
        self.url = url
        self.token = token
        self.deviceID = deviceID
    }
}

extension IMHelloOK {
    /// 从线路形状（snake_case）的 `sys.hello.ok` data 解出来；`limits` 缺省时各项为 0。
    init(wire data: [String: IMJSON]) {
        let limits = data["limits"]?.objectValue ?? [:]
        self.init(
            uid: Wire.string(data, "uid"),
            deviceID: Wire.string(data, "device_id"),
            sessionID: Wire.string(data, "session_id"),
            resumed: Wire.bool(data, "resumed"),
            pingIntervalSec: Int(Wire.int(data, "ping_interval_sec")),
            tokenExpiresAtMS: Wire.int(data, "token_expires_at_ms"),
            maxFrameBytes: Int(Wire.int(limits, "max_frame_bytes")),
            maxCallees: Int(Wire.int(limits, "max_callees")),
            maxRoomParticipants: Int(Wire.int(limits, "max_room_participants")),
            ringTimeoutSecDefault: Int(Wire.int(limits, "ring_timeout_sec_default")))
    }
}
