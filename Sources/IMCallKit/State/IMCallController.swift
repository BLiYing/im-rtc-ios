import Foundation
#if canImport(UIKit)
import UIKit
import AVFoundation
#endif
import IMCallEngine

/*
 把 Engine 的公开回调接成界面状态。

 # 这一整个文件里没有一处「内部 API」

 它实现的是 `IMCallEngineDelegate`（见 IMCallController+Delegate.swift）—— 与「宿主自画 UI」
 拿到的东西**完全一致**。这是产品边界的直接体现：**缺信息就补回调表，不开后门**。

 # 发布是 Kit 的活

 Engine 在 `call.connected` 之后会自动进房，但**不会自动推流**——
 推不推、推麦克风还是也推摄像头，是界面的决定。所以这里在 callBegin 之后发布。

 # 权限先于信令

 拨出 / 接听之前先过权限门（IMCallController+Permissions.swift）：拿不到麦克风就不该去响别人的铃。
 */

/// 界面状态变化的观察者。
public protocol IMCallControllerObserver: AnyObject {
    func callController(_ controller: IMCallController, didChange state: IMCallViewState)
}

/// Kit 的状态中枢。**回调都在主线程**（Engine 已经切好了）。
@objc public final class IMCallController: NSObject {
    public private(set) var state = IMCallViewState() {
        didSet {
            guard state != oldValue else { return }
            onStateChanged(from: oldValue)
            broadcast()
        }
    }

    /// 正在显示的权限说明 / 被拒卡；nil = 没有。变化也走 `broadcast()`。
    public private(set) var promptCard: IMPromptCard?
    /// 「添加成员」的候选名单（静态兜底，保留兼容），由 `IMCallKitConfig.inviteCandidates` 灌进来。
    /// **取名单优先级**（§3.4）：宿主接管选人页 > `inviteMemberProvider` > 这份静态名单 > 空态。
    @objc public var inviteCandidates: [IMInviteCandidate] = []
    /// 按通话要候选人的钩子（HOST_INTEGRATION_DESIGN §3.4）。**强引用**——与 `profileResolver`
    /// 不同，provider 多半是宿主专为通话场景造的一次性对象，Kit 需要保它活到通话结束。
    /// 由 `IMCallKitConfig.inviteMemberProvider` 灌进来。
    @objc public var inviteMemberProvider: IMInviteMemberProvider?
    /// uid 输入框默认关（§3.4）：打开后只出现在候选名单为空的空态里，只给 Demo 用。
    @objc public var allowsManualUIDInput = false
    /// 身份解析器，由 `IMCallKitConfig.profileResolver` 灌进来。**弱引用**：
    /// 宿主多半让自己的某个长生命周期对象来实现它，Kit 不该延长它的寿命。
    @objc public weak var profileResolver: IMProfileResolving?
    /// Kit 的配置（2026-09-16 新增）；铃声三个字段要现用现读，见 IMCallController+Ringtone.swift。
    @objc public var config = IMCallKitConfig()

    /// 宿主的身份解析回来了，重画用到这些 uid 的地方。
    ///
    /// **参数目前只用于日志**：一次通话最多 9 个格子，整屏重画比按 uid 精细失效便宜得多，
    /// 也少一类「漏刷某一格」的 bug。签名保留 uids 是为了将来真需要精细化时不破坏调用方。
    @objc public func reloadProfiles(_ uids: [String]) {
        broadcast()
    }

    let engine: IMCallEngine
    /// 弹一句提示的出口，由 UI 层（`IMCallWindow`）挂上，见 `IMCallController+Busy.swift`。nil（没有 UI）时退回通话界面里的 hint。
    var noticeHandler: ((String) -> Void)?
    private let observers = NSHashTable<AnyObject>.weakObjects()
    /// ObjC 可用的状态观察者（`IMCallControllerStateObserver`，见 `IMCallController+ObjC.swift`）。
    /// 与 `observers` 分开一张表：`IMCallControllerObserver` 是非 `@objc` 的 Swift 协议，
    /// ObjC 类型天生实现不了，只能另起一张表、另一套广播。
    let objcObservers = NSHashTable<AnyObject>.weakObjects()
    /// block 形式的状态观察者，按注册顺序（见 `addStateChangeHandler(_:)`）。**只在主线程读写**。
    var stateChangeHandlers: [(token: UUID, handler: (IMCallController) -> Void)] = []
    /// 本端已发布轨道的 cid。**不进 state**：它不参与渲染。
    var micCID = ""
    /// 本端摄像头轨道的 cid：**可能只是预览、还没发布**（拨出中 / 来电页上起的预览），看 `cameraPublished`。
    var cameraCID = ""
    /// `cameraCID` 真的推上房间了没有。只起过预览的 cid 调 `setMuted` 只开关轨道、不发信令——
    /// 靠「cid 非空」判「已发布」的话，来电页上开过又关掉摄像头再接听，通话中再打开就只是解除静音，对端永远看不到。
    var cameraPublished = false
    /// 预览正在起，防来电页每次重画都再起一路。
    var previewStarting = false
    /// 预览代际。关掉预览时 +1，还在路上的那次起预览回来认得出自己作废了（见 `stopLocalPreview`）。
    var previewEpoch = 0
    /// 已经为哪个房间发布过。防止同一个房间推两次流。
    private var publishedRoomID = ""
    /// 结束画面停留多久再自动收起。0 = 不自动收。
    @objc public var endedHoldSeconds: TimeInterval = 1.5
    private var dismissTimer: DispatchSourceTimer?

    /// 红键按下之后盯着这一屏走没走的那只表。见 `armEndWatchdog`。
    var endWatchdog: DispatchSourceTimer?
    /// 提示自动撤掉的计时器。**提示是一次性的**：不撤的话它在 `statusLine` 里永久顶掉时长。
    var hintTimer: DispatchSourceTimer?
    /// 邀请中的占位格拿到终局后停 2s 再收的计时器，按 uid 记。
    var settleTimers: [String: DispatchSourceTimer] = [:]
    /// 切后台时被自动暂停的摄像头；回前台恢复。**不改用户的开关**。
    var cameraPausedByBackground = false
    /// 系统网络换了就叫 Engine 立即重连，见 `IMNetworkWatcher`。
    private var networkWatcher: IMNetworkWatcher?
    /// 最后一批邀请出去的 uid。加人被拒时用它把占位格收回来。
    private var lastInvited: [String] = []
    #if canImport(UIKit)
    var ringtonePlayer: AVAudioPlayer? // 起停逻辑见 IMCallController+Ringtone.swift。
    var ringtoneKind: IMRingtoneKind = .none
    var vibrationTimer: DispatchSourceTimer? // 来电振动，同上。
    #endif
    /// 系统权限探针。**只这一份、controller 全程复用**——`startRingingPreviewIfAllowed()`
    /// 原先每次来电都 `IMSystemPermissionProbe()` 现造一个，探针本身无状态，没必要每次都新建。
    let systemProbe: IMDevicePermissionProbe = IMSystemPermissionProbe()
    /// 权限门。系统探针默认走 AVFoundation，测试可换。
    lazy var permissionGate = makePermissionGate(systemProbe: systemProbe)

    @objc public init(engine: IMCallEngine) {
        self.engine = engine
        super.init()
        engine.delegate = self
        observeAppLifecycle()
        networkWatcher = IMNetworkWatcher { [weak engine] in engine?.notifyNetworkChanged() }
    }

    deinit {
        // 计时器持有方释放时必须 cancel（CONVENTIONS §5：Timer 的 runloop 语义容易泄漏）。
        dismissTimer?.cancel()
        endWatchdog?.cancel()
        hintTimer?.cancel()
        settleTimers.values.forEach { $0.cancel() }
        #if canImport(UIKit)
        ringtonePlayer?.stop() // 同一条规矩：持有方释放时要停（2026-09-16 新增）。
        vibrationTimer?.cancel()
        #endif
    }

    public func addObserver(_ observer: IMCallControllerObserver) { observers.add(observer) }
    public func removeObserver(_ observer: IMCallControllerObserver) { observers.remove(observer) }

    // MARK: - 界面能做的动作

    /**
     placeCall 拨出。**先过权限门再发 invite**（交互稿 §01）。

     `chatGroupID` / `userData` / `timeoutSec` 原样转给 `IMCallOptions`
     （HOST_INTEGRATION_DESIGN §3.2）：宿主发起「群内通话」时带上自己的群号，
     被叫与中途加入的人才知道这通电话属于哪个群。`timeoutSec` 为 0 时用协议默认值。
     */
    @objc public func placeCall(_ calleeIDs: [String], mediaType: String, isGroup: Bool = false,
                          chatGroupID: String = "", userData: String = "", timeoutSec: Int = 0) {
        guard !blockIfBusy() else { return }
        apply(.callPlaced(calleeIDs: calleeIDs, mediaType: mediaType, isGroup: isGroup))
        Task {
            let outcome = await permissionGate.ensure(
                imPermissionDevicesForPlacing(mediaType: mediaType, isGroup: isGroup))
            guard await settle(outcome, onBlocked: { self.apply(.dismiss) }) else { return }
            // 过完权限门要再看一眼这一屏还在不在，见 `stillOnScreen(expecting:whenGone:)`。
            guard await stillOnScreen(expecting: .outgoing, whenGone: "[Kit] 过完权限门时这一屏已经不在了，invite 不发") else { return }
            // 群通话默认关着摄像头：权限照问（交互稿 §01），摄像头不开。
            await startPreviewIfWanted()
            let options = IMCallOptions(isGroup: isGroup, chatGroupID: chatGroupID,
                                        userData: userData, timeoutSec: timeoutSec)
            do {
                _ = try await engine.call(calleeIDs, mediaType: mediaType, options: options)
            } catch {
                /*
                 被拒时 Engine **先**抛 `callDidEnd(.error)`（界面已经进了结束画面）、**再** throw 到这里。
                 宿主邀请鉴权回调拒绝（1409）与已在别处通话（1408，同账号在别的设备上通话，入口守门拦不到）有专属提示，
                 其余码的收场由 `callDidEnd` 那条路负责。
                 */
                imLogRejected("拨号", error)
                let code = imRTCErrorCode(error)
                if code == IMErrorCode.inviteDenied.rawValue {
                    await MainActor.run { self.apply(.hint(imT("hint.inviteRejected"))) }
                } else if code == IMErrorCode.alreadyInCall.rawValue {
                    await MainActor.run { self.showNotice(imBusyNoticeText) }
                }
            }
        }
    }

    @objc(joinMeetingWithRoomID:roomToken:)
    public func joinMeeting(roomID: String, roomToken: String) {
        guard !blockIfBusy() else { return }
        Task {
            let outcome = await permissionGate.ensure(
                imPermissionDevices(mediaType: "video", withCamera: true))
            guard await settle(outcome, onBlocked: {}) else { return }
            await MainActor.run {
                self.apply(.meetingJoined(roomID: roomID, now: Date().timeIntervalSince1970))
                if outcome == .cameraBlocked { self.apply(.cameraBlocked) }
            }
            await startPreviewIfWanted()
            do {
                /*
                 **会议房发 `"audio"`**（MEETING_ROOM_DESIGN §4.3）：音频由服务端自动订上，
                 页外的人说话照样听得见；视频一条都不自动订，由分页画廊按当前页
                 `setRemoteLayer` 订与退。发 `"all"` 的话 25 人会议一进房就订满 24 路视频，
                 sub offer 直接撞上 64 KiB 的帧上限——那正是 M2 要解决的那堵墙。
                */
                try await engine.joinRoom(roomID, roomToken: roomToken, autoSubscribe: "audio")
            } catch {
                // 服务端拒绝时 Engine 已经抛过 `didLeaveRoom`（界面随它收起）；本地就拒掉的（2005 / 2007）
                // 没有那条回调，自己把「接通中…」收回来。进房没成就不推流。
                imLogRejected("进会议", error)
                await MainActor.run {
                    if self.state.phase == .connecting, self.state.roomID == roomID { self.apply(.dismiss) }
                }
                return
            }
            await publishFor(mediaType: "video")
        }
    }

    /**
     接听。**先过权限门再发 accept**——先 accept 再发现没权限，对方那边已经接通了却听不到人。
     来电页上亲手关掉了摄像头才只问麦克风（= 以语音接听，拍板 §11-10）；群通话默认关着进来不算，
     照样问（交互稿 §01）。接不了就拒掉，别让对方一直等。
     */
    @objc public func accept() {
        let devices = imPermissionDevicesForAnswering(mediaType: state.mediaType,
                                                      cameraOptedOut: state.selfState.cameraOptedOut)
        Task {
            let outcome = await permissionGate.ensure(devices)
            guard await settle(outcome, onBlocked: { self.rejectLogged() }) else { return }
            // 同 `placeCall`：权限门期间对方可能已经取消、用户也可能已经按了拒接。
            guard await stillOnScreen(expecting: .incoming, whenGone: "[Kit] 过完权限门时这通来电已经不在了，accept 不发") else { return }
            await startPreviewIfWanted()
            // 接听被拒（通话已结束 / 已在别处处理）：Engine 退回 idle 并抛 callDidEnd(.error)，界面随它收起。
            do { try await engine.accept() } catch { imLogRejected("接听", error) }
        }
    }

    /// 拒接失败时 Engine 本地照样收场，错误只留痕。
    @objc public func reject() { rejectLogged() }

    private func rejectLogged() {
        Task {
            do { try await engine.reject() } catch { imLogRejected("拒接", error) }
        }
    }

    /**
     stillOnScreen 在过完权限门之后再确认这一屏还在——`placeCall` 与 `accept` 共用。

     权限门可能停在系统框 / 说明卡上好几秒，这期间用户完全可能已经按了红键
     （甚至已经被 `armEndWatchdog` 本地收场）。不看的话：屏幕早就收了，
     invite / accept 却在用户授权的那一刻才发出去。

     `expectedPhase` 是这一动作期望当时处在的阶段（`placeCall` 是 `.outgoing`、
     `accept` 是 `.incoming`）；不在了就记一条 `whenGone` 日志，返回 `false`。
     */
    private func stillOnScreen(expecting expectedPhase: IMCallPhase, whenGone: String) async -> Bool {
        let stillThere = await MainActor.run { self.state.phase == expectedPhase }
        guard stillThere else {
            IMRTCLog.warn(whenGone)
            return false
        }
        return true
    }

    /// 前后摄像头翻转。**纯媒体动作，不改视图状态**——镜像由媒体层自己处理。
    @objc public func switchCamera() {
        Task {
            do { try await engine.switchCamera() } catch { imLogRejected("翻转摄像头", error) }
            /*
             **翻完要重画一次。**

             镜像与否取决于「现在是不是前置」，而那个状态不在 `IMCallViewState` 里
             （它归媒体层），所以 `state` 一个字都没变、`didSet` 也就不会触发。
             不补这一下，翻到后置之后画面还镜像着，直到下一次别的事件来重画。
            */
            await MainActor.run { self.broadcast() }
        }
    }

    /// 当前是不是前置摄像头。**本端预览要不要镜像看它**——后置绝不能镜像。
    @objc public var isUsingFrontCamera: Bool { engine.isUsingFrontCamera }

    @objc public func toggleSpeaker() {
        let on = !state.selfState.speakerOn
        apply(.setSpeaker(on))
        engine.setSpeakerOn(on)
    }

    /**
     结束当前这一场。红按钮在**四种场合是四个不同的动作**，分辨这件事是 Kit 的责任（`imEndAction`）。

     发出去之后还要**盯着这一屏到底走没走**（`armEndWatchdog`）：认得出该发哪一帧，
     不等于那一帧真的发得出去。
     */
    @objc public func end() {
        let action = imEndAction(for: state)
        // **按下红键要留一条**：2026-09-13 14:54 那次到底按没按、按的时候在哪个阶段，事后只能靠猜。
        IMRTCLog.info("[Kit] 按下红键", ["action": action.rawValue, "phase": String(describing: state.phase)])
        armEndWatchdog(reason: imEndWatchdogReason(for: action))
        Task {
            // 退出类失败时 Engine 本地照样收场（callDidEnd / didLeaveRoom 照发），错误只留痕。
            do {
                switch action {
                case .leaveRoom: try await engine.leaveRoom()
                case .reject:    try await engine.reject()
                case .cancel:    try await engine.cancel()
                case .hangup:    try await engine.hangup()
                }
            } catch {
                imLogRejected("红键（\(action.rawValue)）", error)
            }
        }
    }

    /// inviteMore 往群通话里加人：占位格**立刻**出现，帧随后才发（交互稿 §05 G3）。
    ///
    /// 记下这一批是谁：服务端拒掉（1407 本端不在通话里 / 1202 满员 / 1409 宿主拒绝）时不会有 `userDidReject`——
    /// 那条是给「真的响了铃的人」的。不收回占位格的话它们会一直挂着「呼叫中…」，还占着人数。
    /// 失败的码从 `engine.inviteMore` 的 throw 里取，见 `handleInviteMoreFailure(_:)`。
    @objc public func inviteMore(_ uids: [String]) {
        guard !uids.isEmpty else { return }
        lastInvited = uids
        apply(.invited(uids: uids))
        Task {
            do {
                try await engine.inviteMore(uids)
            } catch {
                imLogRejected("加人", error)
                await MainActor.run { self.handleInviteMoreFailure(error) }
            }
        }
    }

    /// 把最后一批邀请的占位格收回来（加人被服务端拒时）。
    func revokeLastInvite() {
        let uids = lastInvited
        lastInvited = []
        for uid in uids where !(state.participants.first { $0.uid == uid }?.hasAccepted ?? false) {
            apply(.userRemove(uid: uid))
        }
    }

    /// reportLayer 报某人画面的层上界（协议 §3.5）。格子越小报得越低，直接省带宽。
    @objc(reportLayer:layer:)
    public func reportLayer(_ uid: String, _ layer: String) {
        Task { await engine.setRemoteLayer(uid, layer: layer) }
    }

    @objc public func setMinimized(_ minimized: Bool) { apply(.setMinimized(minimized)) }
    /// setSwapped 互换 1v1 的两块画面。纯本端行为。
    @objc public func setSwapped(_ swapped: Bool) { apply(.setSwapped(swapped)) }
    @objc public func dismiss() { apply(.dismiss) }

    #if canImport(UIKit)
    /// 把某人的远端画面挂到一个视图上；传 nil 卸载。Kit 走的是门面的公开方法，与宿主自画 UI 完全一样。
    @objc public func attachView(_ uid: String, to view: UIView?) { engine.attachView(uid, to: view) }

    /// 把**本端摄像头**挂到视图上做预览；传 nil 卸载。cid 由 controller 记着，界面不需要知道。
    @objc(attachLocalPreviewToView:)
    public func attachLocalPreview(to view: UIView?) {
        guard !cameraCID.isEmpty else { return }
        engine.attachLocalView(cameraCID, to: view)
    }

    /// 本端有没有摄像头轨道可预览。没有的话格子该显示头像。
    @objc public var hasLocalCamera: Bool { !cameraCID.isEmpty }
    #endif

    // MARK: - 内部

    /// broadcast 无条件把当前状态推给观察者。cid / 提示卡这类变化不在 state 里，靠它通知。
    func broadcast() {
        observers.allObjects.forEach {
            ($0 as? IMCallControllerObserver)?.callController(self, didChange: state)
        }
        objcObservers.allObjects.forEach {
            ($0 as? IMCallControllerStateObserver)?.callControllerDidUpdateState(self)
        }
        // 遍历的是数组副本：回调里退订自己（或别人）不影响这一轮。
        stateChangeHandlers.forEach { $0.handler(self) }
    }

    func apply(_ action: IMCallViewAction) {
        state = reduceCallView(state, action)
    }

    /// showPrompt 出一张卡；由 IMCallWindow 画。
    func showPrompt(_ card: IMPromptCard?) {
        promptCard = card
        broadcast()
    }

    /// settle 把权限门的结局翻成「要不要继续」。走不下去时执行 `onBlocked`。
    func settle(_ outcome: IMPermissionOutcome,
                        onBlocked: @escaping @MainActor () -> Void) async -> Bool {
        switch outcome {
        case .ok:
            return true
        case .cameraBlocked:
            await MainActor.run { self.apply(.cameraBlocked) }
            return true
        case .cancelled, .micBlocked:
            await MainActor.run(body: onBlocked)
            return false
        }
    }

    /// onStateChanged 处理「状态变了之后要做的事」：结束态自动收起、归零清账、进房后推流、终局计时。
    private func onStateChanged(from before: IMCallViewState) {
        #if canImport(UIKit)
        updateRingtone() // 铃声起停的唯一挂载点（2026-09-16 新增），见 IMCallController+Ringtone.swift。
        updateVibration() // 来电振动，同一个挂载点、同一个理由。
        #endif
        dismissTimer?.cancel()
        dismissTimer = nil
        /*
         收到终态就不必再盯着。**挂在这里而不是各个回调里**：onStateChanged 是状态变更的
         唯一出口，漏挂一条回调就会多出一次莫名其妙的「本地收场」。
        */
        if state.phase == .idle || state.phase == .ended {
            endWatchdog?.cancel()
            endWatchdog = nil
        }
        if state.phase == .ended, endedHoldSeconds > 0 {
            dismissTimer = imAfter(imEndedHoldSeconds(state.endReason), on: .main) { [weak self] in self?.apply(.dismiss) }
        }
        if state.phase == .idle {
            /*
             **这一屏没了，权限卡不能还杵在上面。** 卡是 `promptCard`，不在 state 里，
             所以阶段回到 idle 它一个字都不会变。更要紧的是那张卡背后挂着一个
             continuation：不替用户答一声，`placeCall` / `accept` 的那个 Task 会一直悬着。
             答 false = 「取消」，权限门回 `.cancelled`，调用方按取消收场。
            */
            promptCard?.answer(false)
            micCID = ""
            cameraCID = ""
            cameraPublished = false
            previewStarting = false
            previewEpoch += 1
            publishedRoomID = ""
            cameraPausedByBackground = false
            settleTimers.values.forEach { $0.cancel() }
            settleTimers = [:]
        }
        scheduleSettledRemovals()
        scheduleHintExpiry(from: before)
        /*
         有房间号且还没为它发布过 → 推流。判据不是「阶段正好是 connecting」——
         connecting 可能一帧都不停留（callBegin 与 roomJoined 几乎同时到达）。
         */
        let isLive = state.phase == .connecting || state.phase == .active
        // 还不在通话里、或还没拿到房号：正常，不值得记。
        guard isLive, !state.roomID.isEmpty else { return }
        /*
         **跳过发布要留一条。**

         这段每次状态变化都会跑，绝大多数时候「跳过」是正常的（同一个房间已经发过了）。
         但它也是一整类 bug 的藏身处：web 端同一道闸就因为房号没被清零，
         在「挂断后重进同一房间」时一声不响地吃掉整个发布——界面正常、日志空白、
         对端只看到首字母头像，三个观测面同时是瞎的（真机 2026-09-09 14:43）。

         所以只在**「已经在通话里、房号也有了，却仍然不发布」**这种真正可疑的情形下记一条。
         正常复发时一通电话只出现一次，噪声可以忽略；出问题时它是唯一的线索。
        */
        guard publishedRoomID != state.roomID else {
            IMRTCLog.debug("[Kit] 跳过发布：这个房间已经发过了", ["room_id": state.roomID])
            return
        }
        publishedRoomID = state.roomID
        guard !state.isMeeting else {
            IMRTCLog.debug("[Kit] 跳过发布：会议由 joinMeeting 自己推流", ["room_id": state.roomID])
            return
        }
        let mediaType = state.mediaType
        engine.setSpeakerOn(state.selfState.speakerOn)
        Task { await publishFor(mediaType: mediaType) }
    }

}
