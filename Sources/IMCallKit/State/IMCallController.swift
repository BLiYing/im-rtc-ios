import Foundation
#if canImport(UIKit)
import UIKit
#endif
import IMCallEngine

/*
 把 Engine 的公开回调接成界面状态。

 # 这一整个文件里没有一处「内部 API」

 它实现的是 `IMCallEngineDelegate` —— 与「宿主自画 UI」拿到的东西**完全一致**。
 这是产品边界的直接体现：**缺信息就补回调表，不开后门**。
 哪天 Kit 需要 Engine 开一个私有口子，就说明那张表少了一项。

 # 发布是 Kit 的活

 Engine 在 `call.connected` 之后会自动进房，但**不会自动推流**——
 推不推、推麦克风还是也推摄像头，是界面的决定。所以这里在 callBegin 之后发布。
 */

/// 界面状态变化的观察者。
public protocol IMCallControllerObserver: AnyObject {
    func callController(_ controller: IMCallController, didChange state: IMCallViewState)
}

/// Kit 的状态中枢。**回调都在主线程**（Engine 已经切好了）。
public final class IMCallController: NSObject {
    public private(set) var state = IMCallViewState() {
        didSet {
            guard state != oldValue else { return }
            observers.allObjects.forEach {
                ($0 as? IMCallControllerObserver)?.callController(self, didChange: state)
            }
        }
    }

    private let engine: IMCallEngine
    private let observers = NSHashTable<AnyObject>.weakObjects()
    /// 本端已发布轨道的 cid。**不进 state**：它不参与渲染。
    private var micCID = ""
    private var cameraCID = ""
    /// 已经为哪个房间发布过。防止同一个房间推两次流。
    private var publishedRoomID = ""
    /// 「以语音接听」的记号：callBegin 之后推流时不带摄像头。
    private var audioOnlyAccept = false
    /// 结束画面停留多久再自动收起。0 = 不自动收。
    public var endedHoldSeconds: TimeInterval = 1.5
    private var dismissTimer: DispatchSourceTimer?

    public init(engine: IMCallEngine) {
        self.engine = engine
        super.init()
        engine.delegate = self
    }

    deinit {
        // 计时器持有方释放时必须 cancel（CONVENTIONS §5：Timer 的 runloop 语义容易泄漏）。
        dismissTimer?.cancel()
    }

    public func addObserver(_ observer: IMCallControllerObserver) {
        observers.add(observer)
    }

    public func removeObserver(_ observer: IMCallControllerObserver) {
        observers.remove(observer)
    }

    // MARK: - 界面能做的动作

    public func placeCall(_ calleeIDs: [String], mediaType: String, isGroup: Bool = false) {
        apply(.callPlaced(calleeIDs: calleeIDs, mediaType: mediaType, isGroup: isGroup))
        Task {
            // 视频呼出时**先把本端预览起起来**：拨出中还没有房间，推不了流，
            // 但界面这时就该让人看见自己（草图 §03-E）。采集与发布是两件事。
            if mediaType == "video" { await startPreview() }
            await engine.call(calleeIDs, mediaType: mediaType, isGroup: isGroup)
        }
    }

    /**
     startPreview 起本端采集（不发布）。失败只记日志——预览不该挡住通话。

     采集起来之后**必须无条件通知一次界面**，不能只靠 `apply(.setCamera(true))`：
     视频通话的 `cameraOn` 本来就是 true，那一次 apply 前后状态相等，
     `state.didSet` 直接不发通知，于是**没人去调 `attachLocalPreview`**——
     画面挂不上。真机上的表现是「拨出时看不见自己，随手点一下静音又出来了」，
     因为静音真的改了状态，顺带触发了一次重挂。
    */
    private func startPreview() async {
        guard cameraCID.isEmpty else { return }
        do {
            cameraCID = try await engine.startLocalPreview()
            await MainActor.run {
                self.apply(.setCamera(true))
                self.broadcast()
            }
        } catch {
            IMRTCLog.info("本端预览起不来", ["err": String(describing: error)])
        }
    }

    public func joinMeeting(roomID: String, roomToken: String) {
        apply(.meetingJoined(roomID: roomID, now: Date().timeIntervalSince1970))
        Task {
            await engine.joinRoom(roomID, roomToken: roomToken)
            await publishFor(mediaType: "video")
            await MainActor.run { self.apply(.setCamera(true)) }
        }
    }

    public func accept() {
        Task {
            if state.mediaType == "video" { await startPreview() }
            await engine.accept()
        }
    }
    public func reject() { Task { await engine.reject() } }

    /// 以语音接听视频来电（草图 §03-F）：接了，但**本端不开摄像头**。
    /// 对方照常推视频，我们照常收；只是自己不发。
    public func acceptAudioOnly() {
        apply(.setCamera(false))
        apply(.setSpeaker(false))
        audioOnlyAccept = true
        Task { await engine.accept() }
    }

    public func toggleSpeaker() {
        let on = !state.selfState.speakerOn
        apply(.setSpeaker(on))
        engine.setSpeakerOn(on)
    }

    /**
     结束当前这一场，不管它是通话还是会议。

     红按钮在**四种场合是四个不同的动作**，分辨这件事是 Kit 的责任——
     让调用方去分辨，迟早有人分辨错。最容易错的是最后一条：
     **会议房里没有 call**，发 hangup 会被状态机本地拒成 2005，
     按钮点了毫无反应、人退不出房间（Web 端三人会议实测撞出来的）。
     */
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

    public func toggleCamera() {
        let on = !state.selfState.cameraOn
        apply(.setCamera(on))
        Task {
            // 第一次开摄像头要真的发布；之后只是开关，**不走 unpublish**——
            // 反复 publish/unpublish 会触发重协商风暴（协议 §3.2）。
            if cameraCID.isEmpty, on {
                cameraCID = (try? await engine.publishCamera()) ?? ""
            } else if !cameraCID.isEmpty {
                await engine.setMuted(cameraCID, muted: !on)
            }
        }
    }

    #if canImport(UIKit)
    /**
     把某人的远端画面挂到一个视图上；传 nil 卸载。

     **这条路一开始整条漏了**：格子画好了、媒体也协商通了，但没人调
     `attachView`，于是画面永远不出现——而且不报任何错。
     Kit 走的是门面的公开方法，与「宿主自画 UI」完全一样（CONVENTIONS §1）。
     */
    public func attachView(_ uid: String, to view: UIView?) {
        engine.attachView(uid, to: view)
    }

    /// 把**本端摄像头**挂到视图上做预览；传 nil 卸载。
    /// cid 由 controller 记着，界面不需要知道。
    public func attachLocalPreview(to view: UIView?) {
        guard !cameraCID.isEmpty else { return }
        engine.attachLocalView(cameraCID, to: view)
    }

    /// 本端摄像头轨道的 cid；结束时用来卸载预览。
    var localCameraCID: String { cameraCID }

    /// 本端有没有摄像头轨道可预览。没有的话格子该显示头像。
    public var hasLocalCamera: Bool { !cameraCID.isEmpty }
    #endif

    /// reportLayer 报某人画面的层上界（协议 §3.5）。格子越小报得越低，直接省带宽。
    public func reportLayer(_ uid: String, _ layer: String) {
        Task { await engine.setRemoteLayer(uid, layer: layer) }
    }

    public func setMinimized(_ minimized: Bool) { apply(.setMinimized(minimized)) }
    public func dismiss() { apply(.dismiss) }

    // MARK: - 内部

    /// broadcast 无条件把当前状态推给观察者。
    ///
    /// `state.didSet` 只在**状态真的变了**时通知，这对渲染是对的，
    /// 但「本端轨道好了」这类变化不在 state 里（cid 不参与渲染），
    /// 靠 apply 一个恰好相等的状态是通知不出去的。
    private func broadcast() {
        observers.allObjects.forEach {
            ($0 as? IMCallControllerObserver)?.callController(self, didChange: state)
        }
    }

    private func apply(_ action: IMCallViewAction) {
        let before = state
        state = reduceCallView(state, action)
        onPhaseChanged(from: before)
    }

    /// onPhaseChanged 处理两件「状态变了之后要做的事」。
    private func onPhaseChanged(from before: IMCallViewState) {
        // 1. 进了结束态就排一个自动收起。**必须先 cancel 旧的**，
        //    否则快速连打两通会互相收掉。
        dismissTimer?.cancel()
        dismissTimer = nil
        if state.phase == .ended, endedHoldSeconds > 0 {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            // 「对方不在线」这类要让人看清，正常挂断不用停那么久。
            timer.schedule(deadline: .now() + imEndedHoldSeconds(state.endReason))
            timer.setEventHandler { [weak self] in self?.apply(.dismiss) }
            dismissTimer = timer
            timer.resume()
        }
        // 2. 回到 idle 就清掉发布记录，下一通才不会拿着上一通的 cid 去 mute。
        if state.phase == .idle {
            micCID = ""
            cameraCID = ""
            publishedRoomID = ""
            audioOnlyAccept = false
        }
        /*
         3. 有房间号且还没为它发布过 → 推流。

         触发条件看的是**「有房间号且没推过」**，不是「阶段正好是 connecting」——
         connecting 可能一帧都不停留：callBegin 与 roomJoined 几乎同时到达时，
         中间那个状态根本没被观察到。（Web 端被 jsdom 用例抓出来过。）
         */
        let isLive = state.phase == .connecting || state.phase == .active
        guard isLive, !state.roomID.isEmpty, publishedRoomID != state.roomID else { return }
        publishedRoomID = state.roomID
        guard !state.isMeeting else { return } // 会议由 joinMeeting 自己推流
        let mediaType = audioOnlyAccept ? "audio" : state.mediaType
        // 接通那一刻把扬声器路由落到媒体层——之前只是界面上的默认值。
        engine.setSpeakerOn(state.selfState.speakerOn)
        Task { await publishFor(mediaType: mediaType) }
    }

    private func publishFor(mediaType: String) async {
        micCID = (try? await engine.publishMicrophone()) ?? ""
        // 摄像头可能已经在预览了；publishCamera 会复用同一条轨道，不重开设备。
        if mediaType == "video" {
            cameraCID = (try? await engine.publishCamera()) ?? cameraCID
        }
        /*
         发布是异步的，**这期间用户完全可能已经点过静音或关摄像头**——
         那两个开关都以 `cid.isEmpty` 为由静默跳过了，只改了界面。
         不在这里补一遍的话，界面显示「已静音」而对方照样听得见。
        */
        let wanted = await MainActor.run { self.state.selfState }
        if !micCID.isEmpty, !wanted.micOn { await engine.setMuted(micCID, muted: true) }
        if !cameraCID.isEmpty, !wanted.cameraOn { await engine.setMuted(cameraCID, muted: true) }
        // cid 不在 state 里，状态相等时 didSet 不会通知——本端预览要靠这一下才挂得上。
        await MainActor.run { self.broadcast() }
    }
}

/*
 回调表的实现。**每一条都只用 delegate 给的参数**——没有一处去 engine 里"多问一句"。
 */
extension IMCallController: IMCallEngineDelegate {
    public func callEngine(_ engine: IMCallEngine, didReceiveCall callID: String,
                           caller: String, mediaType: String, isGroup: Bool) {
        apply(.callReceived(callID: callID, caller: caller,
                            mediaType: mediaType, isGroup: isGroup))
    }

    public func callEngine(_ engine: IMCallEngine, callDidBegin callID: String, roomID: String,
                           mediaType: String, isGroup: Bool, role: String) {
        apply(.callBegin(callID: callID, roomID: roomID, mediaType: mediaType,
                         isGroup: isGroup, role: role, now: Date().timeIntervalSince1970))
    }

    public func callEngine(_ engine: IMCallEngine, callDidEnd callID: String, reason: String,
                           durationSec: Int, endedBy: String) {
        apply(.callEnd(reason: reason))
    }

    // 会议没有 callDidEnd，收尾只能靠这两条。漏订阅的话离房成功了界面还挂在那儿。
    public func callEngine(_ engine: IMCallEngine, didLeaveRoom roomID: String) {
        apply(.roomLeft)
    }

    public func callEngine(_ engine: IMCallEngine, roomDidClose roomID: String, reason: String) {
        apply(.roomLeft)
    }

    public func callEngine(_ engine: IMCallEngine, didJoinRoom roomID: String) {
        apply(.mediaReady)
    }

    public func callEngine(_ engine: IMCallEngine, didReceiveFirstVideoFrame uid: String,
                           trackID: String) {
        apply(.mediaReady)
    }

    public func callEngine(_ engine: IMCallEngine, userDidEnter uid: String) {
        apply(.userEnter(uid: uid))
    }

    public func callEngine(_ engine: IMCallEngine, userDidLeave uid: String) {
        apply(.userLeave(uid: uid))
    }

    public func callEngine(_ engine: IMCallEngine, userDidAccept uid: String) {
        apply(.userAccept(uid: uid))
    }

    // 拒接与无应答要把格子收掉——不收的话那一格一直挂着「（响铃中）」，
    // 从主叫的角度看，对方拒接就跟什么都没发生一样。
    public func callEngine(_ engine: IMCallEngine, userDidReject uid: String) {
        apply(.userSettled(uid: uid))
    }

    public func callEngine(_ engine: IMCallEngine, userDidNotRespond uid: String) {
        apply(.userSettled(uid: uid))
    }

    public func callEngine(_ engine: IMCallEngine, user uid: String, audioAvailable available: Bool) {
        apply(.userAudio(uid: uid, available: available))
    }

    public func callEngine(_ engine: IMCallEngine, user uid: String, videoAvailable available: Bool) {
        apply(.userVideo(uid: uid, available: available))
    }

    public func callEngine(_ engine: IMCallEngine,
                           activeSpeakersDidChange speakers: [[String: Any]]) {
        apply(.activeSpeakers(speakers.map {
            (uid: $0["uid"] as? String ?? "", volume: ($0["volume"] as? NSNumber)?.intValue ?? 0)
        }))
    }

    public func callEngine(_ engine: IMCallEngine,
                           networkQualityDidChange entries: [[String: Any]]) {
        apply(.networkQuality(entries.map {
            (uid: $0["uid"] as? String ?? "", level: ($0["level"] as? NSNumber)?.intValue ?? 0)
        }))
    }

    // 四个便利事件只在 1v1 抛，随后必有 callDidEnd——所以这里只做提示，**不改阶段**。
    public func callEngine(_ engine: IMCallEngine, callWasRejectedBy uid: String) {
        apply(.hint("\(uid) 已拒接"))
    }

    public func callEngine(_ engine: IMCallEngine, calleeIsBusy uid: String) {
        apply(.hint("\(uid) 忙线中"))
    }

    public func callEngine(_ engine: IMCallEngine, calleeDidNotAnswer uid: String) {
        apply(.hint("\(uid) 无应答"))
    }

    public func callEngine(_ engine: IMCallEngine, callWasCancelledBy uid: String) {
        apply(.hint("\(uid) 取消了呼叫"))
    }
}
