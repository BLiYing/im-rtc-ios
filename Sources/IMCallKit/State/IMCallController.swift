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

    let engine: IMCallEngine
    private let observers = NSHashTable<AnyObject>.weakObjects()
    /// 本端已发布轨道的 cid。**不进 state**：它不参与渲染。
    var micCID = ""
    var cameraCID = ""
    /// 已经为哪个房间发布过。防止同一个房间推两次流。
    private var publishedRoomID = ""
    /// 结束画面停留多久再自动收起。0 = 不自动收。
    public var endedHoldSeconds: TimeInterval = 1.5
    private var dismissTimer: DispatchSourceTimer?
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
                imPermissionDevices(mediaType: mediaType, withCamera: true))
            guard await settle(outcome, onBlocked: { self.apply(.dismiss) }) else { return }
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
            await engine.joinRoom(roomID, roomToken: roomToken)
            await publishFor(mediaType: "video")
        }
    }

    /**
     接听。**先过权限门再发 accept**——先 accept 再发现没权限，对方那边已经接通了却听不到人。
     来电页上关掉了摄像头就只问麦克风（= 以语音接听，拍板 §11-10）。接不了就拒掉，别让对方一直等。
     */
    public func accept() {
        let devices = imPermissionDevices(mediaType: state.mediaType,
                                          withCamera: state.selfState.cameraOn)
        Task {
            let outcome = await permissionGate.ensure(devices)
            guard await settle(outcome, onBlocked: { Task { await self.engine.reject() } }) else { return }
            await engine.accept()
        }
    }

    public func reject() { Task { await engine.reject() } }

    /// 前后摄像头翻转。**纯媒体动作，不改视图状态**——镜像由媒体层自己处理。
    public func switchCamera() {
        Task { await engine.switchCamera() }
    }

    public func toggleSpeaker() {
        let on = !state.selfState.speakerOn
        apply(.setSpeaker(on))
        engine.setSpeakerOn(on)
    }

    /// 结束当前这一场。红按钮在**四种场合是四个不同的动作**，分辨这件事是 Kit 的责任（`imEndAction`）。
    public func end() {
        let action = imEndAction(for: state)
        Task {
            switch action {
            case .leaveRoom: await engine.leaveRoom()
            case .reject:    await engine.reject()
            case .cancel:    await engine.cancel()
            case .hangup:    await engine.hangup()
            }
        }
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
        guard !state.roomID.isEmpty else { return }
        Task {
            // 第一次开摄像头要真的发布；之后只是开关，**不走 unpublish**（协议 §3.2 的重协商风暴）。
            guard cameraCID.isEmpty, on else {
                if !cameraCID.isEmpty { await engine.setMuted(cameraCID, muted: !on) }
                return
            }
            do {
                cameraCID = try await engine.publishCamera()
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
        if state.phase == .ended, endedHoldSeconds > 0 {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + imEndedHoldSeconds(state.endReason))
            timer.setEventHandler { [weak self] in self?.apply(.dismiss) }
            dismissTimer = timer
            timer.resume()
        }
        if state.phase == .idle {
            micCID = ""
            cameraCID = ""
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
        guard isLive, !state.roomID.isEmpty, publishedRoomID != state.roomID else { return }
        publishedRoomID = state.roomID
        guard !state.isMeeting else { return } // 会议由 joinMeeting 自己推流
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
