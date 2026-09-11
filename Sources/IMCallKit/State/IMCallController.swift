import Foundation
#if canImport(UIKit)
import UIKit
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

/// 「添加成员」的候选人。**名单是宿主给的**——Kit 不内置联系人系统（CONVENTIONS §11）。
@objc public final class IMInviteCandidate: NSObject {
    @objc public let uid: String
    @objc public let name: String
    @objc public init(uid: String, name: String = "") {
        self.uid = uid
        self.name = name.isEmpty ? uid : name
    }
}

/// Kit 的状态中枢。**回调都在主线程**（Engine 已经切好了）。
public final class IMCallController: NSObject {
    public private(set) var state = IMCallViewState() {
        didSet {
            guard state != oldValue else { return }
            onStateChanged(from: oldValue)
            broadcast()
        }
    }

    /// 正在显示的权限说明 / 被拒卡；nil = 没有。变化也走 `broadcast()`。
    public private(set) var promptCard: IMPromptCard?
    /// 「添加成员」的候选名单，由 `IMCallKitConfig.inviteCandidates` 灌进来。
    public var inviteCandidates: [IMInviteCandidate] = []
    /// 身份解析器，由 `IMCallKitConfig.profileResolver` 灌进来。**弱引用**：
    /// 宿主多半让自己的某个长生命周期对象来实现它，Kit 不该延长它的寿命。
    public weak var profileResolver: IMProfileResolving?

    /// 宿主的身份解析回来了，重画用到这些 uid 的地方。
    ///
    /// **参数目前只用于日志**：一次通话最多 9 个格子，整屏重画比按 uid 精细失效便宜得多，
    /// 也少一类「漏刷某一格」的 bug。签名保留 uids 是为了将来真需要精细化时不破坏调用方。
    public func reloadProfiles(_ uids: [String]) {
        broadcast()
    }

    let engine: IMCallEngine
    private let observers = NSHashTable<AnyObject>.weakObjects()
    /// 本端已发布轨道的 cid。**不进 state**：它不参与渲染。
    var micCID = ""
    /// 本端摄像头轨道的 cid：**可能只是预览、还没发布**（拨出中 / 来电页上起的预览），看 `cameraPublished`。
    var cameraCID = ""
    /// `cameraCID` 真的推上房间了没有。只起过预览的 cid 调 `setMuted` 只开关轨道、不发信令——
    /// 靠「cid 非空」判「已发布」的话，来电页上开过又关掉摄像头再接听，通话中再打开就只是解除静音，对端永远看不到。
    var cameraPublished = false
    /// 预览正在起，防来电页每次重画都再起一路。
    var previewStarting = false
    /// 已经为哪个房间发布过。防止同一个房间推两次流。
    private var publishedRoomID = ""
    /// 结束画面停留多久再自动收起。0 = 不自动收。
    public var endedHoldSeconds: TimeInterval = 1.5
    private var dismissTimer: DispatchSourceTimer?

    /// 红键按下之后盯着这一屏走没走的那只表。见 `armEndWatchdog`。
    private var endWatchdog: DispatchSourceTimer?
    /// 提示自动撤掉的计时器。**提示是一次性的**：不撤的话它在 `statusLine` 里永久顶掉时长。
    private var hintTimer: DispatchSourceTimer?
    /// 邀请中的占位格拿到终局后停 2s 再收的计时器，按 uid 记。
    private var settleTimers: [String: DispatchSourceTimer] = [:]
    /// 切后台时被自动暂停的摄像头；回前台恢复。**不改用户的开关**。
    private var cameraPausedByBackground = false
    /// 最后一批邀请出去的 uid。加人被拒时用它把占位格收回来。
    private var lastInvited: [String] = []
    /// 权限门。系统探针默认走 AVFoundation，测试可换。
    lazy var permissionGate = makePermissionGate(systemProbe: IMSystemPermissionProbe())

    public init(engine: IMCallEngine) {
        self.engine = engine
        super.init()
        engine.delegate = self
        observeAppLifecycle()
    }

    deinit {
        // 计时器持有方释放时必须 cancel（CONVENTIONS §5：Timer 的 runloop 语义容易泄漏）。
        dismissTimer?.cancel()
        endWatchdog?.cancel()
        hintTimer?.cancel()
        settleTimers.values.forEach { $0.cancel() }
    }

    public func addObserver(_ observer: IMCallControllerObserver) { observers.add(observer) }
    public func removeObserver(_ observer: IMCallControllerObserver) { observers.remove(observer) }

    // MARK: - 界面能做的动作

    /// placeCall 拨出。**先过权限门再发 invite**（交互稿 §01）。
    public func placeCall(_ calleeIDs: [String], mediaType: String, isGroup: Bool = false) {
        apply(.callPlaced(calleeIDs: calleeIDs, mediaType: mediaType, isGroup: isGroup))
        Task {
            let outcome = await permissionGate.ensure(
                imPermissionDevicesForPlacing(mediaType: mediaType, isGroup: isGroup))
            guard await settle(outcome, onBlocked: { self.apply(.dismiss) }) else { return }
            /*
             **过完权限门要再看一眼这一屏还在不在。** 权限门可能停在系统框 / 说明卡上好几秒，
             这期间用户完全可能按了红键（甚至已经被 `armEndWatchdog` 本地收场）。
             不看的话：屏幕早就收了，invite 却在用户授权的那一刻才发出去——
             对方响起铃来，主叫这边一个界面都没有。
            */
            guard await MainActor.run(body: { self.state.phase == .outgoing }) else {
                IMRTCLog.warn("[Kit] 过完权限门时这一屏已经不在了，invite 不发")
                return
            }
            // 群通话默认关着摄像头：权限照问（交互稿 §01），摄像头不开。
            await startPreviewIfWanted()
            await engine.call(calleeIDs, mediaType: mediaType, isGroup: isGroup)
        }
    }

    public func joinMeeting(roomID: String, roomToken: String) {
        Task {
            let outcome = await permissionGate.ensure(
                imPermissionDevices(mediaType: "video", withCamera: true))
            guard await settle(outcome, onBlocked: {}) else { return }
            await MainActor.run {
                self.apply(.meetingJoined(roomID: roomID, now: Date().timeIntervalSince1970))
                if outcome == .cameraBlocked { self.apply(.cameraBlocked) }
            }
            await startPreviewIfWanted()
            await engine.joinRoom(roomID, roomToken: roomToken)
            await publishFor(mediaType: "video")
        }
    }

    /**
     接听。**先过权限门再发 accept**——先 accept 再发现没权限，对方那边已经接通了却听不到人。
     来电页上亲手关掉了摄像头才只问麦克风（= 以语音接听，拍板 §11-10）；群通话默认关着进来不算，
     照样问（交互稿 §01）。接不了就拒掉，别让对方一直等。
     */
    public func accept() {
        let devices = imPermissionDevicesForAnswering(mediaType: state.mediaType,
                                                      cameraOptedOut: state.selfState.cameraOptedOut)
        Task {
            let outcome = await permissionGate.ensure(devices)
            guard await settle(outcome, onBlocked: { Task { await self.engine.reject() } }) else { return }
            // 同 `placeCall`：权限门期间对方可能已经取消、用户也可能已经按了拒接。
            guard await MainActor.run(body: { self.state.phase == .incoming }) else {
                IMRTCLog.warn("[Kit] 过完权限门时这通来电已经不在了，accept 不发")
                return
            }
            await startPreviewIfWanted()
            await engine.accept()
        }
    }

    public func reject() { Task { await engine.reject() } }

    /// 前后摄像头翻转。**纯媒体动作，不改视图状态**——镜像由媒体层自己处理。
    public func switchCamera() {
        Task {
            await engine.switchCamera()
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
    public var isUsingFrontCamera: Bool { engine.isUsingFrontCamera }

    public func toggleSpeaker() {
        let on = !state.selfState.speakerOn
        apply(.setSpeaker(on))
        engine.setSpeakerOn(on)
    }

    /**
     结束当前这一场。红按钮在**四种场合是四个不同的动作**，分辨这件事是 Kit 的责任（`imEndAction`）。

     发出去之后还要**盯着这一屏到底走没走**（`armEndWatchdog`）：认得出该发哪一帧，
     不等于那一帧真的发得出去。
     */
    public func end() {
        let action = imEndAction(for: state)
        armEndWatchdog(reason: imEndWatchdogReason(for: action))
        Task {
            switch action {
            case .leaveRoom: await engine.leaveRoom()
            case .reject:    await engine.reject()
            case .cancel:    await engine.cancel()
            case .hangup:    await engine.hangup()
            }
        }
    }

    /**
     红键的看门狗：按下 `IMEndWatchdogSeconds` 之后这一屏还在原地，就**本地收场**。

     为什么需要它：2026-09-09 在 Android 上复现——摄像头权限设成「每次询问」时权限门在
     拨出中途没落定，`call.invite` **一帧没发**，而界面早已切成 outgoing。红键映射到
     `cancel`，引擎的通话状态机却还在 Idle，于是**本地拒成 2005、一帧不发、
     也没有任何结束事件回来**，界面永远停在「正在呼叫…」。

     iOS 这一侧同形：`placeCall` 也是先 `apply(.callPlaced)` 再过权限门，而
     `imEndAction` 连 Android 那条 `Action.none` 兜底都没有（`default` 直接给 `hangup`）。
     判据因此只能是**「按下之后这一屏到底走没走」**——用户按红键时的意图没有歧义：
     把我弄出去；这条路必须在本地就能走完，不许依赖服务端应答。
     */
    private func armEndWatchdog(reason: String) {
        endWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + IMEndWatchdogSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.endWatchdog = nil
            guard self.state.phase != .idle, self.state.phase != .ended else { return }
            IMRTCLog.warn("[Kit] 红按钮本地收场：没等到结束事件",
                          ["phase": String(describing: self.state.phase)])
            self.apply(.callEnd(reason: reason, durationSec: 0))
        }
        endWatchdog = timer
        timer.resume()
    }

    public func toggleMic() {
        let on = !state.selfState.micOn
        apply(.setMic(on))
        guard !micCID.isEmpty else { return }
        Task { await engine.setMuted(micCID, muted: !on) }
    }

    /// 开关摄像头。**还没进房时只改界面，不去发布**；禁用态点了要出提示，不能静默（规范 §06）。
    public func toggleCamera() {
        if state.selfState.cameraBlocked {
            apply(.hint("没有摄像头权限"))
            return
        }
        let on = !state.selfState.cameraOn
        apply(.setCamera(on))
        guard !state.roomID.isEmpty else {
            // 群通话拨出中打开摄像头：权限拨出前问过了，这时起预览好让人看见自己。
            if on, state.phase == .outgoing { Task { await self.startPreviewIfWanted() } }
            return
        }
        Task {
            // 第一次开摄像头要真的发布；之后只是开关，**不走 unpublish**（协议 §3.2 的重协商风暴）。
            // 判「发布过没有」不看 cid：来电页上起过的预览也有 cid，但从没推上去（见 `cameraPublished`）。
            guard !cameraPublished, on else {
                if cameraPublished { await engine.setMuted(cameraCID, muted: !on) }
                return
            }
            do {
                cameraCID = try await engine.publishCamera() // 有预览轨道时引擎直接复用它
                cameraPublished = true
                await MainActor.run { self.broadcast() }
            } catch {
                /*
                 **发布失败要落到界面上。** 原先是 `try?` 吞掉：抛 2001（用户刚在系统设置里
                 关掉摄像头）时按钮已经乐观地点亮了，**用户以为自己出镜了，对端什么也没收到**。
                 */
                IMRTCLog.warn("[Kit] 开摄像头失败", ["err": String(describing: error)])
                await MainActor.run {
                    self.apply(.setCamera(false))
                    if classifyPermissionError(error) != nil { self.apply(.cameraBlocked) }
                }
            }
        }
    }

    /// inviteMore 往群通话里加人：占位格**立刻**出现，帧随后才发（交互稿 §05 G3）。
    ///
    /// 记下这一批是谁：服务端拒掉（1407 非主叫 / 1202 满员）时不会有 `userDidReject`——
    /// 那条是给「真的响了铃的人」的。不收回占位格的话它们会一直挂着「呼叫中…」，还占着人数。
    public func inviteMore(_ uids: [String]) {
        guard !uids.isEmpty else { return }
        lastInvited = uids
        apply(.invited(uids: uids))
        Task { await engine.inviteMore(uids) }
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
    public func reportLayer(_ uid: String, _ layer: String) {
        Task { await engine.setRemoteLayer(uid, layer: layer) }
    }

    public func setMinimized(_ minimized: Bool) { apply(.setMinimized(minimized)) }
    /// setSwapped 互换 1v1 的两块画面。纯本端行为。
    public func setSwapped(_ swapped: Bool) { apply(.setSwapped(swapped)) }
    public func dismiss() { apply(.dismiss) }

    #if canImport(UIKit)
    /// 把某人的远端画面挂到一个视图上；传 nil 卸载。Kit 走的是门面的公开方法，与宿主自画 UI 完全一样。
    public func attachView(_ uid: String, to view: UIView?) { engine.attachView(uid, to: view) }

    /// 把**本端摄像头**挂到视图上做预览；传 nil 卸载。cid 由 controller 记着，界面不需要知道。
    public func attachLocalPreview(to view: UIView?) {
        guard !cameraCID.isEmpty else { return }
        engine.attachLocalView(cameraCID, to: view)
    }

    /// 本端有没有摄像头轨道可预览。没有的话格子该显示头像。
    public var hasLocalCamera: Bool { !cameraCID.isEmpty }
    #endif

    // MARK: - 内部

    /// broadcast 无条件把当前状态推给观察者。cid / 提示卡这类变化不在 state 里，靠它通知。
    func broadcast() {
        observers.allObjects.forEach {
            ($0 as? IMCallControllerObserver)?.callController(self, didChange: state)
        }
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
    private func settle(_ outcome: IMPermissionOutcome,
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
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + imEndedHoldSeconds(state.endReason))
            timer.setEventHandler { [weak self] in self?.apply(.dismiss) }
            dismissTimer = timer
            timer.resume()
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

    /**
     提示（「通话已满员」「对方已拒接」）**停几秒就撤**。

     `statusLine` 里 hint 优先于时长，不撤的话「通话已满员」会顶着标题栏直到通话结束，
     计时器再也不出现（规范 §08：这些是 toast，不是常驻状态）。
     */
    private func scheduleHintExpiry(from before: IMCallViewState) {
        guard state.hint != before.hint else { return }
        hintTimer?.cancel()
        hintTimer = nil
        guard !state.hint.isEmpty else { return }
        let shown = state.hint
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + IMHintHoldSeconds)
        timer.setEventHandler { [weak self] in
            // 只清掉自己那条：中途又来一条新提示时，不该被上一条的计时器抹掉。
            guard let self, self.state.hint == shown else { return }
            self.apply(.hint(""))
        }
        hintTimer = timer
        timer.resume()
    }

    /// 邀请中的格子拿到终局（已拒绝 / 未接听）后停 2s 再收（交互稿 §05 G3）。
    private func scheduleSettledRemovals() {
        for p in state.participants where p.settled != .none && settleTimers[p.uid] == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + IMSettledHoldSeconds)
            timer.setEventHandler { [weak self] in
                self?.settleTimers[p.uid] = nil
                self?.apply(.userRemove(uid: p.uid))
            }
            settleTimers[p.uid] = timer
            timer.resume()
        }
    }

    func publishFor(mediaType: String) async {
        micCID = (try? await engine.publishMicrophone()) ?? ""
        // **本端摄像头是关着的就不推**：关着接听 = 以语音接听，连开都不开。
        let wantsCamera = await MainActor.run { self.state.selfState.cameraOn }
        if mediaType == "video", wantsCamera {
            do {
                cameraCID = try await engine.publishCamera()
                cameraPublished = true
            } catch {
                IMRTCLog.warn("[Kit] 摄像头推流失败，本通只有声音", ["err": String(describing: error)])
                if classifyPermissionError(error) != nil { await MainActor.run { self.apply(.cameraBlocked) } }
            }
        }
        // 发布是异步的，**这期间用户完全可能已经点过静音或关摄像头**——补一遍，否则界面显示「已静音」而对方照样听得见。
        let wanted = await MainActor.run { self.state.selfState }
        if !micCID.isEmpty, !wanted.micOn { await engine.setMuted(micCID, muted: true) }
        if !cameraCID.isEmpty, !wanted.cameraOn { await engine.setMuted(cameraCID, muted: true) }
        await MainActor.run { self.broadcast() }
    }

    // MARK: - 前后台

    /**
     切后台自动暂停本端视频、回前台恢复（交互稿 §03）。

     iOS 在后台**不允许继续采集摄像头**，对端看到的就是一片黑——比看到头像糟糕得多。
     所以进后台就把摄像头轨道 mute 掉（对端收到「摄像头已关闭」，看到头像）；
     回前台**恢复到用户原来的选择**：他进后台前本来就关着摄像头，回前台不要替他打开。
     */
    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    @objc private func appDidEnterBackground() {
        guard !cameraCID.isEmpty, state.selfState.cameraOn else { return }
        cameraPausedByBackground = true
        Task { await engine.setMuted(cameraCID, muted: true) }
    }

    @objc private func appWillEnterForeground() {
        guard cameraPausedByBackground else { return }
        cameraPausedByBackground = false
        guard !cameraCID.isEmpty, state.selfState.cameraOn else { return }
        Task { await engine.setMuted(cameraCID, muted: false) }
    }
}
