import Foundation

/**
 一通电话结束时的事实汇总（通话记录设计 §4）。字段全部来自 Engine 自己的通话状态，不读线路上没有的东西。

 `isGroup == false` 时 `peer` 是对端 uid（主叫 = 被叫，被叫 = 主叫）；群通话恒空。
 `durationSec` 由服务端给（不变量 I8），未接通恒 0。
 */
@objc public final class IMCallSummary: NSObject {
    @objc public let callID: String
    @objc public let reason: IMCallEndReason
    @objc public let durationSec: Int
    @objc public let endedBy: String
    /// `"audio"` 或 `"video"`。
    @objc public let mediaType: String
    @objc public let isGroup: Bool
    @objc public let chatGroupID: String
    @objc public let caller: String
    /// `"caller"` 或 `"callee"`。
    @objc public let role: String
    @objc public let peer: String
    /// 主叫拨号时透传的宿主私有字符串，原样返回。
    @objc public let userData: String

    init(payload p: [String: Any]) {
        func str(_ k: String) -> String { p[k] as? String ?? "" }
        callID = str("call_id")
        reason = IMCallEndReason.from(wire: str("reason"))
        durationSec = (p["duration_sec"] as? NSNumber)?.intValue ?? 0
        endedBy = str("ended_by")
        mediaType = str("media_type")
        isGroup = (p["is_group"] as? NSNumber)?.boolValue ?? false
        chatGroupID = str("chat_group_id")
        caller = str("caller")
        role = str("role")
        peer = str("peer")
        userData = str("user_data")
        super.init()
    }
}
