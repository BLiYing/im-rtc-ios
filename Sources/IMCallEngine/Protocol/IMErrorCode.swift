import Foundation

/*
 错误码表 —— 与 `im-rtc-server/docs/conformance/error_codes.json` 一一对应。

 **这张表不是各端自己编的**：code、name、msg 三样都是契约的一部分，
 四仓必须发出完全相同的字符串。`ConformanceTests` 会拿向量逐条核对，
 少一个、多一个、msg 差一个字都会失败。

 两组码的区别只有一条：`wire` 里的会出现在 `sys.error` 帧里，
 `local` 里的**永远不上线路**，只经 onError 抛给宿主。
 */
@objc public enum IMErrorCode: Int, Sendable {
    /// 1001 `bad_envelope` —— 信封字段缺失/类型错/data 为 null
    case badEnvelope = 1001
    /// 1002 `unknown_type` —— 未知 type
    case unknownType = 1002
    /// 1003 `not_implemented` —— 会议层留位帧，v1 未实现
    case notImplemented = 1003
    /// 1004 `bad_params` —— data 字段非法：超长、枚举越界、数组含自己
    case badParams = 1004
    /// 1005 `frame_too_large` —— 单帧超过 64 KiB
    case frameTooLarge = 1005
    /// 1006 `protocol_version_unsupported` —— sys.hello.protocol_version 不受支持
    case protocolVersionUnsupported = 1006
    /// 1007 `rate_limited` —— 上行频率超限
    case rateLimited = 1007
    /// 1101 `token_invalid` —— token 签名/受众/绑定关系错
    case tokenInvalid = 1101
    /// 1102 `token_expired` —— token 过期，换新的重试
    case tokenExpired = 1102
    /// 1103 `not_authenticated` —— 未发 sys.hello 就发别的帧
    case notAuthenticated = 1103
    /// 1104 `kicked_out` —— 同 uid 同 device_id 在别处登录
    case kickedOut = 1104
    /// 1105 `session_not_resumable` —— session_id 无效或超出 30s 恢复窗口
    case sessionNotResumable = 1105
    /// 1201 `room_not_found` —— 房间不存在或已关闭
    case roomNotFound = 1201
    /// 1202 `room_full` —— 超出 max_participants
    case roomFull = 1202
    /// 1203 `not_in_room` —— 未 join 就发房间帧
    case notInRoom = 1203
    /// 1204 `already_in_room` —— 重复 join 同一房间
    case alreadyInRoom = 1204
    /// 1205 `room_closed` —— 房间已被解散
    case roomClosed = 1205
    /// 1206 `permission_denied` —— 无该操作权限
    case permissionDenied = 1206
    /// 1207 `participant_not_found` —— 目标 participant 不在房
    case participantNotFound = 1207
    /// 1301 `track_not_found` —— 订阅/退订不存在的 track
    case trackNotFound = 1301
    /// 1302 `publish_denied` —— 同 source 重复发布或房间策略禁止
    case publishDenied = 1302
    /// 1303 `subscribe_denied` —— 订阅自己的 track 或无订阅权限
    case subscribeDenied = 1303
    /// 1304 `sdp_invalid` —— SDP 解析失败/超长/cid 认不回来/在非 offerer 侧发 offer
    case sdpInvalid = 1304
    /// 1305 `pc_not_found` —— pc 对应的 PeerConnection 不存在
    case pcNotFound = 1305
    /// 1306 `layer_unavailable` —— max_layer 取值非法
    case layerUnavailable = 1306
    /// 1307 `codec_unsupported` —— SDP 里没有共同编码
    case codecUnsupported = 1307
    /// 1401 `call_not_found` —— call_id 不存在
    case callNotFound = 1401
    /// 1402 `call_ended` —— 通话已结束，客户端必须静默吞掉
    case callEnded = 1402
    /// 1403 `callee_offline` —— 保留：v1 走 call.ended{offline} 而非报错
    case calleeOffline = 1403
    /// 1404 `callee_busy` —— 保留：v1 走 call.ended{busy} 而非报错
    case calleeBusy = 1404
    /// 1405 `invalid_call_state` —— 在错误状态下 accept/reject/cancel/hangup
    case invalidCallState = 1405
    /// 1406 `too_many_callees` —— callee_ids 超上限
    case tooManyCallees = 1406
    /// 1407 `not_call_owner` —— 非主叫发 call.cancel / call.invite_more
    case notCallOwner = 1407
    /// 1408 `already_in_call` —— 自己已在别的通话中
    case alreadyInCall = 1408
    /// 1501 `internal` —— 内部错误兜底
    case internalError = 1501
    /// 1502 `sfu_unavailable` —— 无可用 SFU 节点
    case sfuUnavailable = 1502
    /// 1503 `shutting_down` —— 服务端正在优雅关闭
    case shuttingDown = 1503
    /// 1504 `store_error` —— 持久化失败
    case storeError = 1504
    /// 2001 `device_permission_denied` —— 用户拒绝麦克风/摄像头权限
    case devicePermissionDenied = 2001
    /// 2002 `device_not_found` —— 没有可用的采集设备
    case deviceNotFound = 2002
    /// 2003 `network_unreachable` —— 信令连不上、DNS/TLS 失败
    case networkUnreachable = 2003
    /// 2004 `signaling_timeout` —— 请求 10 秒无应答
    case signalingTimeout = 2004
    /// 2005 `invalid_state` —— 宿主在错误状态下调 Engine 方法
    case invalidState = 2005
    /// 2006 `media_negotiation_failed` —— PeerConnection 协商失败 / ICE failed
    case mediaNegotiationFailed = 2006
    /// 2007 `not_logged_in` —— 未 login 就调业务方法
    case notLoggedIn = 2007
}

extension IMErrorCode {
    /// name 是协议里的稳定名字（snake_case），日志与跨端对账都用它。
    public var name: String {
        Self.definitions[self]?.name ?? "unknown"
    }

    /// message 是给开发者看的英文固定短语。
    ///
    /// **禁止直接显示给用户**：UI 文案由端上按 code 查本地化表。
    /// 它之所以也进契约，是为了四端日志能对得上——同一个码在三个仓里
    /// 打出三种说法，联调时就没法搜。
    public var message: String {
        Self.definitions[self]?.message ?? "unknown error"
    }

    /// isRetryable 表示「同样的请求重试还有意义」。
    public var isRetryable: Bool {
        Self.definitions[self]?.retryable ?? false
    }

    /// isLocal 表示这个码**永不上线路**，只会本地抛给宿主。
    public var isLocal: Bool {
        Self.definitions[self]?.isLocal ?? false
    }

    /// definition 按码查；未知码返回 nil（收到没见过的码要容忍，不能崩）。
    public static func named(_ name: String) -> IMErrorCode? {
        byName[name]
    }

    struct Definition {
        let name: String
        let message: String
        let retryable: Bool
        let isLocal: Bool
    }

    static let definitions: [IMErrorCode: Definition] = [
        .badEnvelope: Definition(name: "bad_envelope", message: "malformed envelope", retryable: false, isLocal: false),
        .unknownType: Definition(name: "unknown_type", message: "unknown frame type", retryable: false, isLocal: false),
        .notImplemented: Definition(name: "not_implemented", message: "frame not implemented", retryable: false, isLocal: false),
        .badParams: Definition(name: "bad_params", message: "invalid frame parameters", retryable: false, isLocal: false),
        .frameTooLarge: Definition(name: "frame_too_large", message: "frame too large", retryable: false, isLocal: false),
        .protocolVersionUnsupported: Definition(name: "protocol_version_unsupported", message: "protocol version unsupported", retryable: false, isLocal: false),
        .rateLimited: Definition(name: "rate_limited", message: "rate limited", retryable: true, isLocal: false),
        .tokenInvalid: Definition(name: "token_invalid", message: "token invalid", retryable: false, isLocal: false),
        .tokenExpired: Definition(name: "token_expired", message: "token expired", retryable: true, isLocal: false),
        .notAuthenticated: Definition(name: "not_authenticated", message: "not authenticated", retryable: false, isLocal: false),
        .kickedOut: Definition(name: "kicked_out", message: "kicked out", retryable: false, isLocal: false),
        .sessionNotResumable: Definition(name: "session_not_resumable", message: "session not resumable", retryable: false, isLocal: false),
        .roomNotFound: Definition(name: "room_not_found", message: "room not found", retryable: false, isLocal: false),
        .roomFull: Definition(name: "room_full", message: "room is full", retryable: false, isLocal: false),
        .notInRoom: Definition(name: "not_in_room", message: "not in room", retryable: false, isLocal: false),
        .alreadyInRoom: Definition(name: "already_in_room", message: "already in room", retryable: false, isLocal: false),
        .roomClosed: Definition(name: "room_closed", message: "room closed", retryable: false, isLocal: false),
        .permissionDenied: Definition(name: "permission_denied", message: "permission denied", retryable: false, isLocal: false),
        .participantNotFound: Definition(name: "participant_not_found", message: "participant not found", retryable: false, isLocal: false),
        .trackNotFound: Definition(name: "track_not_found", message: "track not found", retryable: false, isLocal: false),
        .publishDenied: Definition(name: "publish_denied", message: "publish denied", retryable: false, isLocal: false),
        .subscribeDenied: Definition(name: "subscribe_denied", message: "subscribe denied", retryable: false, isLocal: false),
        .sdpInvalid: Definition(name: "sdp_invalid", message: "sdp invalid", retryable: false, isLocal: false),
        .pcNotFound: Definition(name: "pc_not_found", message: "peer connection not found", retryable: false, isLocal: false),
        .layerUnavailable: Definition(name: "layer_unavailable", message: "layer unavailable", retryable: false, isLocal: false),
        .codecUnsupported: Definition(name: "codec_unsupported", message: "codec unsupported", retryable: false, isLocal: false),
        .callNotFound: Definition(name: "call_not_found", message: "call not found", retryable: false, isLocal: false),
        .callEnded: Definition(name: "call_ended", message: "call already ended", retryable: false, isLocal: false),
        .calleeOffline: Definition(name: "callee_offline", message: "callee offline", retryable: false, isLocal: false),
        .calleeBusy: Definition(name: "callee_busy", message: "callee busy", retryable: false, isLocal: false),
        .invalidCallState: Definition(name: "invalid_call_state", message: "invalid call state", retryable: false, isLocal: false),
        .tooManyCallees: Definition(name: "too_many_callees", message: "too many callees", retryable: false, isLocal: false),
        .notCallOwner: Definition(name: "not_call_owner", message: "not call owner", retryable: false, isLocal: false),
        .alreadyInCall: Definition(name: "already_in_call", message: "already in call", retryable: false, isLocal: false),
        .internalError: Definition(name: "internal", message: "internal error", retryable: true, isLocal: false),
        .sfuUnavailable: Definition(name: "sfu_unavailable", message: "sfu unavailable", retryable: true, isLocal: false),
        .shuttingDown: Definition(name: "shutting_down", message: "server shutting down", retryable: true, isLocal: false),
        .storeError: Definition(name: "store_error", message: "store error", retryable: true, isLocal: false),
        .devicePermissionDenied: Definition(name: "device_permission_denied", message: "device permission denied", retryable: false, isLocal: true),
        .deviceNotFound: Definition(name: "device_not_found", message: "device not found", retryable: false, isLocal: true),
        .networkUnreachable: Definition(name: "network_unreachable", message: "network unreachable", retryable: true, isLocal: true),
        .signalingTimeout: Definition(name: "signaling_timeout", message: "signaling timeout", retryable: true, isLocal: true),
        .invalidState: Definition(name: "invalid_state", message: "invalid state", retryable: false, isLocal: true),
        .mediaNegotiationFailed: Definition(name: "media_negotiation_failed", message: "media negotiation failed", retryable: false, isLocal: true),
        .notLoggedIn: Definition(name: "not_logged_in", message: "not logged in", retryable: false, isLocal: true),
    ]

    static let byName: [String: IMErrorCode] = {
        var out: [String: IMErrorCode] = [:]
        for (code, def) in definitions { out[def.name] = code }
        return out
    }()
}

/// IMRTCError 是本 SDK 抛出的唯一错误类型。
///
/// 带上 `detail` 是给开发者定位用的**内部信息**，不对外透传（协议 §7）：
/// 发给对端的 `sys.error` 帧里只放 code 与 name。
public struct IMRTCError: Error, Equatable, Sendable {
    public let code: IMErrorCode
    public let detail: String

    public init(_ code: IMErrorCode, _ detail: String = "") {
        self.code = code
        self.detail = detail
    }
}

extension IMRTCError: CustomStringConvertible {
    public var description: String {
        detail.isEmpty ? "\(code.name)(\(code.rawValue))" : "\(code.name)(\(code.rawValue)): \(detail)"
    }
}
