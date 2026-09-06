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
 判据类的纯函数（红按钮四向分派、要不要加人入口、用哪种版式）在 `IMCallViewRules.swift`。
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
    /// 已结束。**Engine 的状态机里没有 `ended` 状态**——这是纯展示态（草图 §09 那个停 1.5 秒的方框）。
    case ended
}

/// 邀请中的成员给出的终局：拒了 / 没接 / 不在线。`none` = 还没有终局。有终局的格子停 2s 再移除（交互稿 §05 G3）。
public enum IMSettledOutcome: String, Sendable {
    case none = ""
    case rejected
    case noAnswer = "no_answer"
    case offline
}

/// 信令连接的状态，驱动顶部的橙条。
public enum IMConnectionStatus: String, Sendable {
    case ok, reconnecting, lost
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
    /// 邀请中的格子拿到的终局。
    public var settled: IMSettledOutcome

    /**
     - Note: `hasAudio` 默认 **true**。`userAudioAvailable` 只在状态**变化**时才抛，
       一开始就正常的人不会有事件——默认 false 会让所有人一进来都显示成静音。
     */
    public init(uid: String, hasAccepted: Bool) {
        self.uid = uid
        self.hasAudio = true
        self.hasVideo = false
        self.isSpeaking = false
        self.volume = 0
        self.hasAccepted = hasAccepted
        self.networkLevel = 0
        self.settled = .none
    }
}

/// 本端的开关状态。
public struct IMSelfState: Equatable, Sendable {
    public var micOn = true
    public var cameraOn = false
    /// 扬声器外放。**视频通话默认开**：举着手机看画面时不可能贴耳朵听筒。
    public var speakerOn = false
    /// 摄像头权限被拒（或没有设备）。**通话继续，只是没有画面**（交互稿 §02 P3）：按钮变禁用态写「无权限」。
    public var cameraBlocked = false

    public init(micOn: Bool = true, cameraOn: Bool = false, speakerOn: Bool = false,
                cameraBlocked: Bool = false) {
        self.micOn = micOn
        self.cameraOn = cameraOn
        self.speakerOn = speakerOn
        self.cameraBlocked = cameraBlocked
    }
}

/// 整个通话界面需要的全部数据。
public struct IMCallViewState: Equatable, Sendable {
    public var phase: IMCallPhase = .idle
    public var callID = ""
    public var roomID = ""
    public var mediaType = "audio"
    public var isGroup = false
    /// 是不是「直接进会议房」而来的。**界面必须分得清**：会议房里根本没有 call，红按钮走 hangup 会被拒成 2005。
    public var isMeeting = false
    public var role = ""
    /// 1v1 的对端 uid；群通话为空串。
    public var peerUID = ""
    public var participants: [IMParticipant] = []
    public var selfState = IMSelfState()
    /// 是否收进悬浮小窗。
    public var isMinimized = false
    /// 1v1 视频里两块画面是否互换了（交互稿 §04）：false = 远端全屏、本端小窗。纯本端行为，但层上界要跟着换。
    public var isSwapped = false
    /// 接通时刻（`Date` 的秒），0 = 还没接通。计时器从它开始走。
    public var beganAt: TimeInterval = 0
    public var endReason = ""
    /// 一句给用户看的提示（「对方已拒接」这类）。
    public var hint = ""
    /// 媒体是否已经就绪。**单独记**：`callBegin` 与「媒体通了」谁先到都可能。
    public var isMediaReady = false
    public var connection: IMConnectionStatus = .ok
    /// 还能不能加人。主叫默认能；收到 `1407 not_call_owner` 后关掉（正常情况下非主叫根本看不到按钮，这条是兜底）。
    public var canInvite = true

    public init() {}

    /// 此刻界面上该不该有通话 UI。
    public var isVisible: Bool { phase != .idle }
}

/// 驱动视图模型的输入。**写成显式枚举而不是把回调表整个映射过来**：看得出「界面到底用了哪几个」。
public enum IMCallViewAction: Sendable {
    /// `calleeIDs` 是这通电话邀了谁（**已去掉自己**）。群通话靠它把还没接的人摆成占位格。
    case callReceived(callID: String, caller: String, calleeIDs: [String],
                      mediaType: String, isGroup: Bool)
    case callPlaced(calleeIDs: [String], mediaType: String, isGroup: Bool)
    case callBegin(callID: String, roomID: String, mediaType: String,
                   isGroup: Bool, role: String, now: TimeInterval)
    case callEnd(reason: String)
    case meetingJoined(roomID: String, now: TimeInterval)
    case roomLeft
    case mediaReady
    /// 摄像头拿不到（权限被拒 / 没设备）：通话继续，按钮禁用。
    case cameraBlocked
    /// 主叫往群通话里又拉了一批人，先摆上占位格。
    case invited(uids: [String])
    case userEnter(uid: String)
    case userLeave(uid: String)
    case userAccept(uid: String)
    /// 某人给出了终局裁决（拒接 / 无应答 / 不在线），格子先标上终局、稍后再收。
    case userSettled(uid: String, outcome: IMSettledOutcome)
    /// 终局停够了，把格子收掉。
    case userRemove(uid: String)
    /// 服务端说不是主叫（1407）：藏掉加人入口。
    case inviteDenied
    case userAudio(uid: String, available: Bool)
    case userVideo(uid: String, available: Bool)
    case activeSpeakers([(uid: String, volume: Int)])
    case networkQuality([(uid: String, level: Int)])
    case connection(IMConnectionStatus)
    case hint(String)
    case setMic(Bool)
    case setCamera(Bool)
    case setSpeaker(Bool)
    case setMinimized(Bool)
    case setSwapped(Bool)
    case dismiss
}

/// 视图模型的唯一入口。**纯函数**。
public func reduceCallView(_ state: IMCallViewState,
                           _ action: IMCallViewAction) -> IMCallViewState {
    var next = state
    switch action {
    case let .callReceived(callID, caller, calleeIDs, mediaType, isGroup):
        next = IMCallViewState()
        next.connection = state.connection
        next.phase = .incoming
        next.callID = callID
        next.mediaType = mediaType
        next.isGroup = isGroup
        next.role = "callee"
        next.peerUID = isGroup ? "" : caller
        /*
         主叫先摆上（他一定在通话里），其余被邀请的人摆成「还在响铃」的占位格。

         不摆的话群通话在两侧长得不一样：主叫看到四格（含没接的），被叫只看到两格。
         `calleeIDs` 里已经由调用方去掉了自己。
        */
        next.participants = [IMParticipant(uid: caller, hasAccepted: true)]
            + calleeIDs.filter { $0 != caller }.map { IMParticipant(uid: $0, hasAccepted: false) }
        next.selfState = IMSelfState(micOn: true, cameraOn: mediaType == "video",
                                     speakerOn: mediaType == "video")

    case let .callPlaced(calleeIDs, mediaType, isGroup):
        next = IMCallViewState()
        next.connection = state.connection
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
        // callBegin 只说「通话建立」，媒体不一定通了，所以先进 connecting——除非媒体已经先一步就绪。
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
        next.connection = state.connection
        // 会议没有振铃，进来就是「接通中」；媒体一通就转 active。
        next.phase = .connecting
        next.roomID = roomID
        next.mediaType = "video"
        next.isGroup = true
        next.isMeeting = true
        next.beganAt = now
        next.selfState = IMSelfState(micOn: true, cameraOn: true, speakerOn: true)

    case let .callEnd(reason):
        // **振铃通话的结束出口**（会议走 roomLeft）。还在响铃的来电直接收起，不留结束画面：
        // 被叫这一侧什么都还没做。主叫那一侧要停一下说明原因。
        if state.phase == .incoming {
            next = IMCallViewState()
            next.connection = state.connection
            return next
        }
        next.phase = .ended
        next.endReason = reason
        next.isMinimized = false

    case .roomLeft:
        // 会议的结束出口。**已经在 ended/idle 就不动**：重复进 ended 会把 endReason 抹成空串。
        guard state.phase != .idle, state.phase != .ended else { return state }
        next.phase = .ended
        next.isMinimized = false

    case .mediaReady:
        next.isMediaReady = true
        if state.phase == .connecting { next.phase = .active }

    case .cameraBlocked:
        next.selfState.cameraOn = false
        next.selfState.cameraBlocked = true

    case .dismiss:
        next = IMCallViewState()
        next.connection = state.connection

    case let .invited(uids):
        // 被邀请的人**立刻**占一个格子（交互稿 §05 G3）；已在名单里的不重复加。
        let known = Set(next.participants.map(\.uid))
        next.participants += uids.filter { !known.contains($0) }
            .map { IMParticipant(uid: $0, hasAccepted: false) }

    case let .userEnter(uid), let .userAccept(uid):
        next = withParticipant(next, uid) { $0.hasAccepted = true; $0.settled = .none }

    case let .userLeave(uid), let .userRemove(uid):
        next.participants.removeAll { $0.uid == uid }

    case let .userSettled(uid, outcome):
        // 群通话里某人拒接 / 没接：**先在格子上写明终局，停一会再收**。直接收掉的话拒接就跟没发生过一样。
        // 已接听的人收到终局（理论上不会）直接忽略。
        next.participants = next.participants.map {
            guard $0.uid == uid, !$0.hasAccepted else { return $0 }
            var p = $0
            p.settled = outcome
            return p
        }

    case .inviteDenied:
        next.canInvite = false
        next.hint = "只有发起人可以添加成员"

    case let .userAudio(uid, available):
        next = withParticipant(next, uid) { $0.hasAudio = available }

    case let .userVideo(uid, available):
        next = withParticipant(next, uid) { $0.hasVideo = available }

    case let .activeSpeakers(speakers):
        // **全量快照不是增量**：不在名单里的人要被清成「没在说话」。
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

    case let .connection(status):
        next.connection = status

    case let .hint(text):
        next.hint = text

    case let .setMic(on):
        next.selfState.micOn = on

    case let .setCamera(on):
        // 权限被拒时开不了：按钮本来就是禁用态，这里再挡一道免得状态漂移。
        if state.selfState.cameraBlocked && on { return state }
        next.selfState.cameraOn = on

    case let .setSpeaker(on):
        next.selfState.speakerOn = on

    case let .setMinimized(minimized):
        next.isMinimized = minimized

    case let .setSwapped(swapped):
        next.isSwapped = swapped
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
