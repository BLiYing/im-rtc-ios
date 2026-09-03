import Foundation

/*
 通话结束原因 —— 协议 §6。

 **`call.ended` 是唯一终态帧**，reason 是它唯一说明「为什么结束」的字段。
 宿主只监听 onCallEnd 也必须能完整记录一通电话，靠的就是这张表够全。
 */
@objc public enum IMCallEndReason: Int, Sendable, CaseIterable {
    /// 已接通成员主动挂断。
    case hangup
    /// 主叫接通前取消。
    case cancel
    /// 被叫主动拒接。
    case reject
    /// 振铃超时无人接听。
    case noAnswer
    /// 被叫正在另一通电话里。
    case busy
    /// 被叫全部不在线。
    case offline
    /// 本账号另一台设备接听了。
    case answeredElsewhere
    /// 本账号另一台设备拒接了。
    case rejectedElsewhere
    /// 被主持人移出。
    case kicked
    /// 房间被关闭。
    case roomClosed
    /// 网络中断且恢复窗口内没接回来。
    case network
    /// 兜底：**收到不认识的 reason 一律折成它**，绝不崩。
    case error
}

extension IMCallEndReason {
    /// wireValue 是线路上的字符串。
    public var wireValue: String {
        switch self {
        case .hangup: return "hangup"
        case .cancel: return "cancel"
        case .reject: return "reject"
        case .noAnswer: return "no_answer"
        case .busy: return "busy"
        case .offline: return "offline"
        case .answeredElsewhere: return "answered_elsewhere"
        case .rejectedElsewhere: return "rejected_elsewhere"
        case .kicked: return "kicked"
        case .roomClosed: return "room_closed"
        case .network: return "network"
        case .error: return "error"
        }
    }

    /// 从线路字符串解析。**不认识的一律折成 `.error`**——
    /// 这是「新增 reason 不算破坏兼容」（§10）成立的前提。
    public static func from(wire: String) -> IMCallEndReason {
        byWire[wire] ?? .error
    }

    private static let byWire: [String: IMCallEndReason] = {
        var out: [String: IMCallEndReason] = [:]
        for reason in IMCallEndReason.allCases { out[reason.wireValue] = reason }
        return out
    }()
}

public enum IMCallOutcome {
    /// 群通话的主导原因优先级（§6）：**越靠前越"主动"**。
    ///
    /// 一个都没接的群呼要给主叫一个说得清的结论：有人明确拒了就说"被拒接"，
    /// 没人拒但有人忙就说"忙线"，都没有才说"无人接听"。
    /// 全体离线是最弱的信号，排最后。
    public static let groupDominantPriority: [IMCallEndReason] = [
        .reject, .busy, .noAnswer, .offline,
    ]

    /// dominant 从各成员的结局里挑出群通话的主导原因。
    ///
    /// 不在优先级表里的结局（比如 `hangup`）**不参与竞争**——
    /// 它们要么不该出现在"没人接通"的场景，要么由更上层的规则直接决定。
    /// 一个都匹配不上时给 `.noAnswer`：那是最不容易误导用户的说法。
    public static func dominant(_ outcomes: [IMCallEndReason]) -> IMCallEndReason {
        for candidate in groupDominantPriority where outcomes.contains(candidate) {
            return candidate
        }
        return .noAnswer
    }

    /// durationSec 按服务端时钟算通话时长。
    ///
    /// **向下取整不是四舍五入**：1999ms 是 1 秒不是 2 秒。
    /// 未接通（connectedAtMS 为 0）恒为 0——**四端禁止自己算时长**，
    /// 一律用 `call.ended` 里的值，这个函数只给服务端与测试用。
    public static func durationSec(connectedAtMS: Int64, endedAtMS: Int64) -> Int64 {
        guard connectedAtMS > 0, endedAtMS > connectedAtMS else { return 0 }
        return (endedAtMS - connectedAtMS) / 1000
    }
}
