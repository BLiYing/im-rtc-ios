import Foundation

/// call 域：振铃流程。见 §4。
/// **Call 层不碰媒体**——接通后一切走 room 帧，所以这里没有一个 SDP 字段。
enum CallFrames {
    private static let E = IMProtocolEnums.self

    /// 发起通话。
    ///
    /// user_data 是 opaque **字符串**不是对象——宿主要塞任意结构自己序列化。
    /// 这条是为了 C++ 端不必处理任意嵌套（§2.4 规则 5）。服务端原样透传，不解析。
    static let invite: IMFrameFields = [
        // 1v1 恰好 1 个；群 ≤8（房内含主叫共 9 人）。
        "callee_ids": .stringArray,
        "media_type": .enumeration(values: E.mediaTypes, fallback: "audio"),
        "is_group": .bool(),
        // "" = 服务端建房。
        "room_id": .string(),
        "timeout_sec": .int(defaultValue: E.defaultTimeoutSec,
                            min: E.minTimeoutSec, max: E.maxTimeoutSec),
        "user_data": .string(),
    ]

    /// **主叫此时禁止 room.join**——接听前不进 SFU（§4.1）。
    static let inviteOK: IMFrameFields = [
        "call_id": .string(),
        "room_id": .string(),
        "invited_at_ms": .int(),
    ]

    /// 只带 call_id 的上行帧共用（accept / reject / cancel / hangup / join）。
    ///
    /// 接通后主叫也用 hangup，**不用 cancel**——两个词不共用一条路径，
    /// 避免「取消一通已接通的电话」这种歧义。
    static let callID: IMFrameFields = ["call_id": .string()]

    /// 群通话中途加邀（P4）。仅主叫可发。
    static let inviteMore: IMFrameFields = [
        "call_id": .string(),
        "callee_ids": .stringArray,
    ]

    /// 被叫收到的邀请，对应 onCallReceived。
    static let incoming: IMFrameFields = [
        "call_id": .string(),
        "room_id": .string(),
        "caller": .string(),
        "callee_ids": .stringArray,
        "media_type": .enumeration(values: E.mediaTypes, fallback: "audio"),
        "is_group": .bool(),
        "timeout_sec": .int(defaultValue: E.defaultTimeoutSec,
                            min: E.minTimeoutSec, max: E.maxTimeoutSec),
        "invited_at_ms": .int(),
        "user_data": .string(),
    ]

    /// 告诉主叫「对方设备开始响铃了」，每个被叫 uid 只发一次。
    /// UI 据此把「正在呼叫…」改成「等待对方接听…」。它**不对应任何回调**。
    static let ringing: IMFrameFields = [
        "call_id": .string(),
        "uid": .string(),
        "device_count": .int(),
    ]

    /// 某成员的裁决，四个帧共用（call.accepted / rejected / busy / no_answer）。
    static let memberOutcome: IMFrameFields = ["call_id": .string(), "uid": .string()]

    /// 主叫取消，发给全部被叫设备。
    static let cancelled: IMFrameFields = ["call_id": .string(), "by": .string()]

    /// 「可以进房了」，对应 onCallBegin。
    ///
    /// call.accept.ok 是纯 ack，房间信息只在这一条帧里——一个东西一条路径。
    static let connected: IMFrameFields = [
        "call_id": .string(),
        "room_id": .string(),
        // 绑定 (room_id, uid, device_id)，TTL 5 分钟、一次性。**不要整条打日志**。
        "room_token": .string(),
        "media_type": .enumeration(values: E.mediaTypes, fallback: "audio"),
        "is_group": .bool(),
        // 通话时长的起点，服务端时钟。
        "connected_at_ms": .int(),
        "accepted_by": .string(),
    ]

    /// 本账号另一台设备处理了这通电话。
    static let handledElsewhere: IMFrameFields = [
        "call_id": .string(),
        "action": .enumeration(values: E.handledActions, fallback: "accept"),
        "device_id": .string(),
    ]

    /// **唯一终态帧**。
    ///
    /// 铁律：每个成员设备收到且仅收到一条；所有结局都走它；
    /// 宿主只监听它也必须能完整记录一通电话。
    static let ended: IMFrameFields = [
        "call_id": .string(),
        "room_id": .string(),
        "reason": .enumeration(values: E.reasons, fallback: "error"),
        // 未接通恒为 0。**四端禁止自己算时长**（时钟偏移），一律用这个值。
        "duration_sec": .int(),
        "ended_by": .string(),
    ]
}
