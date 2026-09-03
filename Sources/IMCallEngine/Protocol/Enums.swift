import Foundation

/*
 协议枚举：**封闭的小写字符串集合**（§2.4 规则 6）。

 每个枚举都配一个兜底值，收到集合外的值折成它——这是「新增枚举值不算破坏兼容」
 （§10）成立的前提：服务端发一个老客户端不认识的值时，老客户端不能崩。

 这里用 `[String]` 常量而不是 Swift `enum`，因为帧声明需要把「合法值集合 + 兜底值」
 当数据传给 `FieldCodec`。面向宿主的强类型枚举在门面层单独定义（且要 `@objc`）。
 */
public enum IMProtocolEnums {
    /// 通话媒体类型。兜底 `audio`——宁可当语音，也不去开一个不存在的摄像头。
    public static let mediaTypes = ["audio", "video"]
    /// 通话结束原因，与 `IMCallEndReason` 同一份。兜底 `error`。
    public static let reasons = [
        "hangup", "cancel", "reject", "no_answer", "busy", "offline",
        "answered_elsewhere", "rejected_elsewhere", "kicked", "room_closed",
        "network", "error",
    ]
    /// simulcast 层。`none` = 暂停下发但保留订阅。兜底 `l`——宁可给小图。
    public static let layers = ["none", "l", "m", "h"]
    /// Track 类型。
    public static let trackKinds = ["audio", "video"]
    /// Track 来源。同一 participant 同一 source 最多一条 Track。
    public static let trackSources = ["microphone", "camera", "screen", "screen_audio"]
    /// 两条 PeerConnection。**每条的 offerer 是固定的**（§3.3）——
    /// pub 由客户端 offer、sub 由服务端 offer。固定 offerer 就没有 glare。
    public static let pcRoles = ["pub", "sub"]
    /// 房间策略预设。
    public static let roomKinds = ["call_1v1", "call_group", "meeting"]
    /// 另一台设备做了什么。
    public static let handledActions = ["accept", "reject"]

    /// 振铃超时的默认值与范围（§2.6）。越界钳到边界，不报错。
    public static let defaultTimeoutSec: Int64 = 30
    /// 振铃超时下界。
    public static let minTimeoutSec: Int64 = 5
    /// 振铃超时上界。
    public static let maxTimeoutSec: Int64 = 120
    /// 网络质量 0 = unknown，也是越界值的兜底。
    public static let qualityUnknown: Int64 = 0
    /// 网络质量上界 6 = 已断开。
    public static let qualityDisconnected: Int64 = 6
}
