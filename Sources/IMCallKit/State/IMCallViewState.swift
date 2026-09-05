import Foundation

/*
 通话界面的视图模型 —— **纯值语义，不碰 UIKit、不碰 Engine**。

 # 为什么要有这一层

 界面上的每个状态都是若干个回调叠加出来的：谁在说话、谁开着摄像头、群里谁还在响铃。
 把这套叠加逻辑写在 ViewController 里，就只能靠点界面来验证；抽成纯函数之后
 它能被逐条驱动（CONVENTIONS §2），**而且不需要模拟器**。

 # 它只消费公开回调表

 输入全部来自 `IMCallEngineDelegate`（= 设计文档 §7.5）。Kit 不是特权组件，
 没有私有通道——**缺信息就补回调表，不开后门**。

 Web 端的同一层是 `packages/call-uikit-react/src/state/callView.ts`，
 两边是同构的：同样的 phase、同样的动作、同样的坑。
 */

/// 界面阶段。**不等于** Engine 状态机的状态。
public enum IMCallPhase: String, Sendable {
    case idle
    /// 收到来电，还没决定。
    case incoming
    /// 已拨出，等对方响应。
    case outgoing
    /// 对方接了，媒体还没通——UI 上是「接通中」。
    case connecting
    /// 通话中。
    case active
    /**
     已结束。

     **Engine 的状态机里没有 `ended` 状态**（ended 是事件）——
     这里的 ended 是纯展示态：草图 §09 那个停 1.5 秒的方框。
     */
    case ended
}

/// 界面上的一个远端成员。
public struct IMParticipant: Equatable, Sendable {
    public let uid: String
    /// 对方麦克风是否可用。
    public var hasAudio: Bool
    /// 对方摄像头是否可用。
    public var hasVideo: Bool
    /// 是否正在说话（服务端节流 300ms）。
    public var isSpeaking: Bool
    /// 0~100 的音量，用来画音量条。
    public var volume: Int
    /// 群通话里是否已接听。false = 还在响铃。
    public var hasAccepted: Bool
    /// 网络质量 0~6，0 = 未知。服务端节流 2s。
    public var networkLevel: Int

    /**
     - Note: `hasAudio` 默认 **true**。`userAudioAvailable` 只在状态**变化**时才抛，
       一开始就正常的人不会有事件——默认 false 会让所有人一进来都显示成静音。
       （Web 端把这条写在同一个位置，是同一个坑。）
     */
    public init(uid: String, hasAccepted: Bool) {
        self.uid = uid
        self.hasAudio = true
        self.hasVideo = false
        self.isSpeaking = false
        self.volume = 0
        self.hasAccepted = hasAccepted
        self.networkLevel = 0
    }
}

/// 本端的开关状态。
public struct IMSelfState: Equatable, Sendable {
    public var micOn = true
    public var cameraOn = false
    /// 扬声器外放。**视频通话默认开**：举着手机看画面时不可能贴耳朵听筒。
    public var speakerOn = false

    public init(micOn: Bool = true, cameraOn: Bool = false, speakerOn: Bool = false) {
        self.micOn = micOn
        self.cameraOn = cameraOn
        self.speakerOn = speakerOn
    }
}

/// 整个通话界面需要的全部数据。
public struct IMCallViewState: Equatable, Sendable {
    public var phase: IMCallPhase = .idle
    public var callID = ""
    public var roomID = ""
    public var mediaType = "audio"
    public var isGroup = false
    /**
     是不是「直接进会议房」而来的，不是振铃通话。

     **界面必须分得清**：会议房里根本没有 call，红按钮走 hangup 会被状态机
     本地拒成 2005——**按钮点了没反应、人退不出去**。会议的结束动作是 leaveRoom。
     （Web 端三人会议实测撞出来的：三端都退不出同一个房间。）
     */
    public var isMeeting = false
    public var role = ""
    /// 1v1 的对端 uid；群通话为空串。
    public var peerUID = ""
    public var participants: [IMParticipant] = []
    public var selfState = IMSelfState()
    /// 是否收进悬浮小窗。
    public var isMinimized = false
    /// 接通时刻（`Date` 的秒），0 = 还没接通。计时器从它开始走。
    public var beganAt: TimeInterval = 0
    public var endReason = ""
    /// 一句给用户看的提示（「对方已拒接」这类）。
    public var hint = ""
    /**
     媒体是否已经就绪。

     **单独记一个标志而不是只看阶段**：`callBegin` 与「媒体通了」谁先到都可能——
     会议场景里进房成功几乎与 callBegin 同时发生，先到的那个如果只在
     「阶段正好是 connecting」时才生效就会被丢掉，界面永远停在「接通中」。
     */
    public var isMediaReady = false

    public init() {}

    /// 此刻界面上该不该有通话 UI。
    public var isVisible: Bool { phase != .idle }
}

/// 驱动视图模型的输入。
///
/// **写成显式枚举而不是把回调表整个映射过来**：映射过来会把 Kit 不消费的回调
/// 也拖进类型里，看不出「界面到底用了哪几个」。
public enum IMCallViewAction: Sendable {
    case callReceived(callID: String, caller: String, mediaType: String, isGroup: Bool)
    case callPlaced(calleeIDs: [String], mediaType: String, isGroup: Bool)
    case callBegin(callID: String, roomID: String, mediaType: String,
                   isGroup: Bool, role: String, now: TimeInterval)
    case callEnd(reason: String)
    case meetingJoined(roomID: String, now: TimeInterval)
    case roomLeft
    case mediaReady
    case userEnter(uid: String)
    case userLeave(uid: String)
    case userAccept(uid: String)
    /// 某人给出了终局裁决（拒接 / 无应答），格子该收掉了。
    case userSettled(uid: String)
    case userAudio(uid: String, available: Bool)
    case userVideo(uid: String, available: Bool)
    case activeSpeakers([(uid: String, volume: Int)])
    case networkQuality([(uid: String, level: Int)])
    case hint(String)
    case setMic(Bool)
    case setCamera(Bool)
    case setSpeaker(Bool)
    case setMinimized(Bool)
    case dismiss
}

/// 视图模型的唯一入口。**纯函数**。
public func reduceCallView(_ state: IMCallViewState,
                           _ action: IMCallViewAction) -> IMCallViewState {
    var next = state
    switch action {
    case let .callReceived(callID, caller, mediaType, isGroup):
        next = IMCallViewState()
        next.phase = .incoming
        next.callID = callID
        next.mediaType = mediaType
        next.isGroup = isGroup
        next.role = "callee"
        next.peerUID = isGroup ? "" : caller
        next.participants = [IMParticipant(uid: caller, hasAccepted: true)]
        next.selfState = IMSelfState(micOn: true, cameraOn: mediaType == "video",
                                     speakerOn: mediaType == "video")

    case let .callPlaced(calleeIDs, mediaType, isGroup):
        next = IMCallViewState()
        next.phase = .outgoing
        next.mediaType = mediaType
        next.isGroup = isGroup
        next.role = "caller"
        next.peerUID = isGroup ? "" : (calleeIDs.first ?? "")
        // 呼出时对方还没接——**先摆上去且标成未接听**，界面才有「正在响铃」的格子。
        next.participants = calleeIDs.map { IMParticipant(uid: $0, hasAccepted: false) }
        next.selfState = IMSelfState(micOn: true, cameraOn: mediaType == "video",
                                     speakerOn: mediaType == "video")

    case let .callBegin(callID, roomID, mediaType, isGroup, role, now):
        // callBegin 只说「通话建立」，媒体不一定通了，所以先进 connecting——
        // 除非媒体已经先一步就绪（会议场景常见）。
        next.phase = state.isMediaReady ? .active : .connecting
        next.callID = callID
        next.roomID = roomID
        next.mediaType = mediaType
        next.isGroup = isGroup
        next.role = role
        next.beganAt = now
        next.hint = ""

    case let .meetingJoined(roomID, now):
        next = IMCallViewState()
        // 会议没有振铃，进来就是「接通中」；媒体一通就转 active。
        next.phase = .connecting
        next.roomID = roomID
        next.mediaType = "video"
        next.isGroup = true
        next.isMeeting = true
        next.beganAt = now
        next.selfState = IMSelfState(micOn: true, cameraOn: true, speakerOn: true)

    case let .callEnd(reason):
        /*
         **振铃通话的结束出口**（会议走 roomLeft）。

         # 还在响铃的来电直接收起，不留结束画面

         被叫这一侧什么都还没做，界面上只有一个来电页。对方取消 / 自己拒接 /
         振铃超时之后，**该做的就是让它消失**——原先统一进 ended，
         于是来电页当场变成通话页的骨架（标题 + 格子 + 本端预览），
         停一两秒再收走。实测反馈是「怎么还弹出一个接通才有的界面」。

         主叫那一侧不一样：拨出去没打通，人是需要知道为什么的
         （对方拒接 / 无人接听 / 不在线），所以那边仍然停一下说明原因。
        */
        if state.phase == .incoming { return IMCallViewState() }
        next.phase = .ended
        next.endReason = reason
        next.isMinimized = false

    case .roomLeft:
        // 会议的结束出口。**已经在 ended/idle 就不动**：通话结束时房间也会被清掉，
        // 那条路已经由 callEnd 收尾了，重复进 ended 会把 endReason 抹成空串。
        guard state.phase != .idle, state.phase != .ended else { return state }
        next.phase = .ended
        next.isMinimized = false

    case .mediaReady:
        next.isMediaReady = true
        if state.phase == .connecting { next.phase = .active }

    case .dismiss:
        next = IMCallViewState()

    case let .userEnter(uid):
        next = withParticipant(next, uid) { $0.hasAccepted = true }

    case let .userLeave(uid):
        next.participants.removeAll { $0.uid == uid }

    case let .userSettled(uid):
        /*
         群通话里某人拒接 / 没接：**把他的格子收掉**。

         不收的话那一格会一直挂着「（响铃中）」——从主叫的角度看，
         对方拒接就跟什么都没发生一样。**这在群通话里是唯一的信号**：
         那边没有便利事件（不变量 I7），只有 onUser*。
         1v1 也会抛，但紧跟着就是 callEnd，界面整个收走，收不收格子都一样。
        */
        next.participants.removeAll { $0.uid == uid }

    case let .userAccept(uid):
        next = withParticipant(next, uid) { $0.hasAccepted = true }

    case let .userAudio(uid, available):
        next = withParticipant(next, uid) { $0.hasAudio = available }

    case let .userVideo(uid, available):
        next = withParticipant(next, uid) { $0.hasVideo = available }

    case let .activeSpeakers(speakers):
        // **全量快照不是增量**：不在名单里的人要被清成「没在说话」，
        // 只加不减的话高亮会一直亮着不灭。
        let volumes = Dictionary(speakers.map { ($0.uid, $0.volume) }) { first, _ in first }
        next.participants = next.participants.map {
            var p = $0
            p.isSpeaking = volumes[p.uid] != nil
            p.volume = volumes[p.uid] ?? 0
            return p
        }

    case let .networkQuality(entries):
        let levels = Dictionary(entries.map { ($0.uid, $0.level) }) { first, _ in first }
        next.participants = next.participants.map {
            guard let level = levels[$0.uid] else { return $0 }
            var p = $0
            p.networkLevel = level
            return p
        }

    case let .hint(text):
        next.hint = text

    case let .setMic(on):
        next.selfState.micOn = on

    case let .setCamera(on):
        next.selfState.cameraOn = on

    case let .setSpeaker(on):
        next.selfState.speakerOn = on

    case let .setMinimized(minimized):
        next.isMinimized = minimized
    }
    return next
}

/// 更新一个成员；**不存在时先补进来**——事件比进房通知先到是常态。
private func withParticipant(_ state: IMCallViewState, _ uid: String,
                             _ update: (inout IMParticipant) -> Void) -> IMCallViewState {
    var next = state
    if let index = next.participants.firstIndex(where: { $0.uid == uid }) {
        update(&next.participants[index])
    } else {
        var fresh = IMParticipant(uid: uid, hasAccepted: true)
        update(&fresh)
        next.participants.append(fresh)
    }
    return next
}

/// 红按钮该发出的那个动作。
public enum IMEndAction: String, Sendable {
    case leaveRoom, cancel, reject, hangup
}

/**
 红按钮在**四种场合是四个不同的动作**，分辨这件事是 Kit 的责任——
 让调用方去分辨，迟早有人分辨错。

 抽成纯函数是因为**最容易错的那一条没法靠点界面发现**：会议房里根本没有 call，
 发 hangup 会被状态机本地拒成 2005 —— 按钮点了毫无反应、人退不出房间，
 而宿主只看到一条没头没尾的 error。（Web 端三人会议实测撞出来的：三端都卡在房里。）
 */
public func imEndAction(for state: IMCallViewState) -> IMEndAction {
    if state.isMeeting { return .leaveRoom }
    switch state.phase {
    case .incoming: return .reject
    case .outgoing: return .cancel
    default:        return .hangup
    }
}

/**
 结束原因的人话。**结束画面必须说清为什么**——只写「通话结束」然后 1.5 秒消失，
 用户根本不知道是对方拒了、忙线、还是压根不在线。
 （实测反馈：拨给不在线的人，界面「消失得很快」且没有任何解释。）

 reason 的取值见 `docs/conformance/reasons.json`，八种；未知值兜底成「已结束」，
 **不显示原始英文**——那是给日志看的，不是给用户看的。
 */
public func imEndReasonText(_ reason: String, role: String, durationSec: Int) -> String {
    switch reason {
    case "hangup":
        // 接通过才有时长；没接通的 hangup 不该出现，真出现了也别显示 00:00。
        return durationSec > 0 ? "通话结束 · \(imFormatDuration(durationSec))" : "通话结束"
    case "cancel":
        return role == "caller" ? "已取消" : "对方已取消"
    case "reject":
        return role == "caller" ? "对方已拒接" : "已拒接"
    case "busy":
        return "对方忙线中"
    case "no_answer":
        return role == "caller" ? "对方无人接听" : "未接来电"
    case "offline":
        // 服务端在被叫一台在线设备都没有时立刻结束，**不振铃**（协议 §4.3）——
        // 对着一个不在的人响 30 秒没有意义。但界面必须说清楚。
        return "对方当前不在线"
    case "network":
        return "网络中断"
    default:
        return "已结束"
    }
}

/// 结束画面停留多久。**说不清原因的那几种要停久一点**：
/// 「对方不在线」得让人看清，而正常挂断谁都知道发生了什么。
public func imEndedHoldSeconds(_ reason: String) -> TimeInterval {
    switch reason {
    case "hangup", "cancel": return 1.5
    default: return 3.0
    }
}
