#if canImport(WebRTC) && canImport(UIKit)
import AVFoundation
import Foundation
import UIKit
import WebRTC
import IMCallEngine

/*
 `IMMediaAdapter` 的 libwebrtc 实现。**Engine 里唯一碰 WebRTC 的地方。**

 换媒体实现（或做 P2P 隐私模式）时只动这个 target，状态机与信令一行不用改。
 不碰可变状态的辅助（权限、挑格式、音频会话、编码参数）在 IMWebRTCAdapter+Support.swift。
 */
public final class IMWebRTCAdapter: NSObject, IMMediaAdapter, @unchecked Sendable {

    /**
     两条 PeerConnection。**通话结束后会被整个换掉，不是复用。**

     `RTCPeerConnection` 一旦 `close()` 就报废了：再往上 `addTransceiver`
     会抛 ObjC 异常，而 Swift 接不住——**进程直接挂掉**。
     原先这里是 `let`，于是第一通电话结束后第二通必崩。
    */
    private var peers: IMPeerConnections?
    private let registry = IMVideoRegistry()
    /// 开关摄像头前后的上行视频采样（排查对端「画面出来又刷新一下」）。见 `IMUplinkVideoStats`。
    private let uplinkVideoStats = IMUplinkVideoStats()
    private var events = IMMediaAdapterEvents()

    /// 本端轨道，按 cid 索引。
    private var localTracks: [String: RTCMediaStreamTrack] = [:]
    /// 摄像头采集器。**必须持有**：不留引用的话它会被释放，画面直接停掉。
    private var capturer: RTCCameraVideoCapturer?
    /// 当前用的是不是前置。翻转靠它决定下一次挑哪一个。
    private var usingFrontCamera = true
    private var videoSource: RTCVideoSource?
    /// 已经在预览的那条摄像头轨道。发布时复用它，不重开设备。
    private var previewTrack: IMLocalTrackInfo?
    /// 已经挂上 pub 的摄像头 cid。**挂过就不再挂**（两条 m-line 发同一条轨道），也不许被 `stopLocalPreview` 停掉。
    private var publishedCameraCID: String?
    /// 通话中关了摄像头：采集停着，轨道与 transceiver 留着（见 `setMuted`）。
    private var capturePaused = false
    /**
     正在起的那一路预览，和起它时的代际。**同一代只起一路**（设计 v3.7 第 5 步）：
     来电页预览还没起来就点接听，`acquireCamera` 紧跟着再要一次——原先两边各开一个采集器抢同一个设备。
     */
    private var opening: (task: Task<IMLocalTrackInfo, Error>, generation: Int)?
    /**
     `lock` 护住**上面所有可变字段**，不只是 `localTracks` 与 `peers`。

     这个类是 `@unchecked Sendable`——那句标注是在向编译器保证「同步我自己来」。
     原先 `capturer` / `videoSource` / `previewTrack` / `syntheticCapturer` /
     `usingFrontCamera` 都在锁外面读写，而 `close()` 由状态机那条线程调、
     `startLocalPreview()` / `switchCamera()` 由界面那条线程调，是实打实的数据竞争。
     */
    private let lock = NSLock()

    /**
     采集代际。`close()` 与进房前的 `stopLocalPreview()` 每次 +1。

     光加锁**治不好跨 await 的那一半**：`startLocalPreview()` 会在系统权限弹窗上
     停好几秒，这期间对端挂断就会走 `close()`（或用户在来电页上关掉了摄像头）。
     等它醒过来接着往下跑，`ensurePeers()` 会现造一对全新的 PC，再把摄像头挂上去——
     通话早就结束了，摄像头却还亮着（iOS 状态栏那个绿点），而轨道挂在一对没人协商的 PC 上；
     下一通电话的 `acquireCamera` 又会因为 `previewTrack` 还在、`localTracks` 已清空
     而抛 `device_not_found`。

     所以每一段跨 await 的采集流程都在开头记下代际，醒来先对一次：
     对不上就说明「我启动的这一轮已经作废」，就地收摊。
     */
    private var captureGeneration = 0

    /// 采集画质档位。见 `IMVideoProfile`：**策略归宿主**，不是服务端下发的。
    private let profile: IMVideoProfile

    /**
     用合成画面代替摄像头（见 `IMSyntheticVideoCapturer`）。

     **模拟器上没有摄像头**，不开这个就只能看头像。**只影响视频**：麦克风照常走真设备
     （模拟器转发宿主 Mac 的），所以「合成音视频」实际上是「合成视频 + 真麦克风」。
     */
    private let syntheticVideo: Bool
    /// 合成画面上写的字（一般是自己的 uid）。
    private let syntheticLabel: String
    /// 合成采集器。与 `capturer` 互斥：开了合成就不建摄像头采集器。
    private var syntheticCapturer: IMSyntheticVideoCapturer?
    /// 下一个上行 offer 要不要带 ICE restart。见 `restartPubICE()`。
    private var pubICERestartPending = false

    /// - Parameters:
    ///   - videoProfile: 画质档位，默认 720p。
    ///   - syntheticVideo: 用合成画面代替摄像头。**只给 Demo / 模拟器联调用**，默认关。
    ///   - label: 合成画面上写的字（一般是自己的 uid），多端并排时好认。
    @objc public init(
        videoProfile: IMVideoProfile = .default,
        syntheticVideo: Bool = false,
        label: String = ""
    ) {
        self.profile = videoProfile
        self.syntheticVideo = syntheticVideo
        self.syntheticLabel = label
        super.init()
    }

    public override convenience init() {
        self.init(videoProfile: .default)
    }

    // MARK: - IMMediaAdapter

    public func open(_ events: IMMediaAdapterEvents) {
        self.events = events
        configureAudioSession()
    }

    /// ensurePeers 拿一对可用的 PC；上一对被 close 过就现造一对并接好回调。
    private func ensurePeers() -> IMPeerConnections {
        lock.lock()
        defer { lock.unlock() }
        if let peers { return peers }
        let fresh = IMPeerConnections()
        wire(fresh)
        peers = fresh
        return fresh
    }

    private func wire(_ pcs: IMPeerConnections) {
        pcs.onLocalCandidate = { [weak self] role, candidate in
            self?.events.onLocalCandidate?(role, IMICECandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid ?? "",
                sdpMLineIndex: Int(candidate.sdpMLineIndex)))
        }
        pcs.onStateChange = { [weak self] role, state in
            self?.events.onConnectionStateChange?(role, Self.stateName(state))
        }
        pcs.onRemoteTrack = { [weak self] track in
            self?.handleRemoteTrack(track)
        }
    }

    /**
     acquireMicrophone 拿麦克风轨道挂到 pub 上。

     **cid 由我们自己定**——这一点与 Web 端不同：浏览器不允许自定义
     `MediaStreamTrack.id`，只能先拿轨道再读它的 id；ObjC 版的
     `audioTrackWithTrackId:` 可以直接指定。服务端认的是 msid 的第二段
     （协议 §3.2），而那一段就是 track id，所以指定它即可。
     */
    public func acquireMicrophone() async throws -> IMLocalTrackInfo {
        let cid = "mic-\(UUID().uuidString.prefix(8))"
        let source = ensurePeers().factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil))
        let track = ensurePeers().factory.audioTrack(with: source, trackId: cid)
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["im-rtc"]
        ensurePeers().pub.addTransceiver(with: track, init: transceiverInit)
        remember(cid: cid, track: track)
        return IMLocalTrackInfo(cid: cid, kind: "audio", source: "microphone")
    }

    /**
     probeMicrophone 只问系统要麦克风权限，不开采集。

     系统框由 `AVCaptureDevice.requestAccess` 弹；已授权时它立刻回 true、不弹框。
     被拒映射成 2001——Kit 钉着这个码决定是「整通取消」还是「降级继续」（交互稿 §02）。
     */
    public func probeMicrophone() async throws {
        try await Self.ensureAccess(.audio, what: "麦克风")
    }

    /**
     startLocalPreview 只起采集，不挂 transceiver。**同一时刻只开一路摄像头。**

     正在起的那一路还有效就等它；已经作废（挂断 / 进房前关了摄像头）就先等它把设备放掉，
     再重新开——不然新旧两个采集器会抢同一个设备。
     */
    public func startLocalPreview() async throws -> IMLocalTrackInfo {
        while true {
            lock.lock()
            if let previewTrack {
                lock.unlock()
                return previewTrack
            }
            if let opening {
                let live = opening.generation == captureGeneration
                lock.unlock()
                if live { return try await opening.task.value }
                _ = try? await opening.task.value
                continue
            }
            let generation = captureGeneration
            let task = Task { try await self.openCamera(generation) }
            opening = (task, generation)
            lock.unlock()
            return try await task.value
        }
    }

    /// openCamera 真的开一次摄像头。只由 `startLocalPreview` 调，它保证同一代只有这一路。
    private func openCamera(_ generation: Int) async throws -> IMLocalTrackInfo {
        defer {
            lock.lock()
            if opening?.generation == generation { opening = nil }
            lock.unlock()
        }
        // **合成画面不碰摄像头，所以也不该问摄像头权限**：模拟器上那个框弹出来毫无意义，
        // 而真机上问了又不用，等于白要一次敏感权限。
        if !syntheticVideo {
            // 先问权限再开设备：没这一步的话 libwebrtc 的采集器在被拒时只是静默地不出画面。
            try await Self.ensureAccess(.video, what: "摄像头")
            // 弹窗可能停留好几秒，这期间对端挂断就会走 close()。见 captureGeneration。
            try assertLive(generation)
        }
        let cid = "cam-\(UUID().uuidString.prefix(8))"
        let peers = ensurePeers()
        let source = peers.factory.videoSource()
        let track = peers.factory.videoTrack(with: source, trackId: cid)

        var camera: RTCCameraVideoCapturer?
        var synthetic: IMSyntheticVideoCapturer?
        if syntheticVideo {
            let fake = IMSyntheticVideoCapturer(delegate: source, label: syntheticLabel)
            fake.startCapture(width: profile.width, height: profile.height, fps: profile.frameRate)
            synthetic = fake
            IMRTCLog.info("合成画面已开", [
                "profile": profile.name, "width": String(profile.width),
                "height": String(profile.height), "label": syntheticLabel,
            ])
        } else {
            let real = RTCCameraVideoCapturer(delegate: source)
            try await startCapture(real)
            camera = real
        }
        // 合成画面是摄像头的**替身**，对外必须报 camera：协议的 source 只认
        // microphone | camera | screen | screen_audio，报 "synthetic" 会被服务端 1004 拒掉
        // room.publish，于是模拟器联调时对端永远只看到头像（2026-09-10 实测）。
        let info = IMLocalTrackInfo(cid: cid, kind: "video", source: "camera")

        // **判代际与记账必须在同一次锁里**：分两步的话，`stopLocalPreview` 夹在中间时看到的是
        // 「还没有采集器」、什么都不停，随后这里再把一个亮着的采集器记进来——灯就灭不掉了。
        lock.lock()
        guard generation == captureGeneration else {
            lock.unlock()
            // 采集**已经起来了**才作废的那一种：不停掉的话摄像头就这么一直亮着。
            Self.halt(camera, synthetic)
            throw IMRTCError(.invalidState, "采集还没起来就作废了（通话结束，或关了摄像头）")
        }
        videoSource = source
        capturer = camera
        syntheticCapturer = synthetic
        localTracks[cid] = track
        previewTrack = info
        lock.unlock()
        return info
    }

    /**
     stopLocalPreview 停掉进房前起的预览，**连采集一起停**（设计 v3.7 第 6 步）。

     已经挂上 pub 的不停——通话中关摄像头走 `setMuted`。代际 +1：还在路上的那一路醒来
     认得出自己作废了，会把设备放掉（见 `openCamera`），不会在用户关掉之后又把灯点亮。
     */
    public func stopLocalPreview() {
        lock.lock()
        guard publishedCameraCID == nil else {
            lock.unlock()
            return
        }
        captureGeneration += 1
        let camera = capturer
        let synthetic = syntheticCapturer
        let cid = previewTrack?.cid
        capturer = nil
        syntheticCapturer = nil
        videoSource = nil
        previewTrack = nil
        if let cid { localTracks[cid] = nil }
        lock.unlock()

        Self.halt(camera, synthetic)
        if let cid { registry.remove(owner: imLocalViewKey(cid)) }
    }

    /**
     acquireCamera 拿摄像头轨道挂到 pub 上。

     `simulcast` 为真时**推三层**（rid = h/m/l，协议 §3.5）。三层的
     `scaleResolutionDownBy` 是 1/2/4，服务端按订阅侧报的层上界与带宽估计选一层转发。
     */
    public func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo {
        // **复用预览那条轨道**：拨出时已经开过摄像头了，再开一次会抢设备。
        let info = try await startLocalPreview()
        let cid = info.cid
        lock.lock()
        if publishedCameraCID == cid {
            lock.unlock()
            return info
        }
        // 预览在这之间被关掉了：按作废报 2005，**不能报「没有设备」**——Kit 会把按钮打成「无权限」。
        guard previewTrack?.cid == cid, let track = localTracks[cid] as? RTCVideoTrack else {
            lock.unlock()
            throw IMRTCError(.invalidState, "摄像头在发布前被关掉了")
        }
        publishedCameraCID = cid
        lock.unlock()

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["im-rtc"]
        if simulcast {
            transceiverInit.sendEncodings = Self.simulcastEncodings(profile)
        } else {
            // 单层也要压上限：不压的话 libwebrtc 会往上飙到远高于服务端预算的码率，
            // 而 `bwe.go` 的降层判断正是拿那个预算算的。
            let encoding = RTCRtpEncodingParameters()
            encoding.isActive = true
            encoding.maxBitrateBps = NSNumber(value: profile.maxBitrateBps)
            transceiverInit.sendEncodings = [encoding]
        }
        let transceiver = ensurePeers().pub.addTransceiver(with: track, init: transceiverInit)
        Self.preferResolutionOverFramerate(transceiver?.sender)
        return info
    }

    /// createPubOffer 生成上行 offer。**pub 的 offerer 恒为本端**（协议 §3.3）。
    public func createPubOffer() async throws -> String {
        lock.lock()
        let restart = pubICERestartPending
        pubICERestartPending = false
        lock.unlock()
        if restart { IMRTCLog.info("上行重启 ICE", [:]) }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: restart ? ["IceRestart": "true"] : nil,
            optionalConstraints: nil)
        let offer = try await ensurePeers().pub.offer(for: constraints)
        try await ensurePeers().pub.setLocalDescription(offer)
        return offer.sdp
    }

    /// 见协议里的说明。**置位而不是立刻发帧**：发帧是 Engine 的事。
    public func restartPubICE() {
        lock.lock()
        pubICERestartPending = true
        lock.unlock()
    }

    public func applyPubAnswer(_ sdp: String) async throws {
        try await ensurePeers().setRemoteDescription(
            RTCSessionDescription(type: .answer, sdp: sdp), for: .pub)
    }

    /// answerSubOffer 应答服务端下发的下行 offer。**sub 的 offerer 恒为服务端**。
    public func answerSubOffer(_ sdp: String) async throws -> String {
        try await ensurePeers().setRemoteDescription(
            RTCSessionDescription(type: .offer, sdp: sdp), for: .sub)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer = try await ensurePeers().sub.answer(for: constraints)
        try await ensurePeers().sub.setLocalDescription(answer)
        return answer.sdp
    }

    public func addRemoteCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async throws {
        try await ensurePeers().addRemoteCandidate(
            RTCIceCandidate(sdp: candidate.candidate,
                            sdpMLineIndex: Int32(candidate.sdpMLineIndex),
                            sdpMid: candidate.sdpMid.isEmpty ? nil : candidate.sdpMid),
            for: pc)
    }

    /**
     setMuted 停/复发包。**不是 unpublish**：轨道与协商都保留。

     已发布的摄像头关掉时**连采集一起停**（状态栏绿点灭）；打开时同一个采集器原地再起，
     轨道、transceiver、cid 一个都不变，不重新协商。libwebrtc 把 start / stop 排在
     同一条采集队列上，按调用顺序执行，所以快速开关不会乱序。

     # 画布「关」的时候就换，「开」的时候只放行第一帧

     轨道对象没变，登记表不会走「换轨道先摘旧帧」那条路，关闭前的最后一帧会一直留在渲染视图里。
     原先「开」的时候才换，可 Kit 按下按钮的同一拍就把格子显出来了，这里却是从 Task 异步回主线程——
     中间一两帧露的正是旧画面。现在关的时候换成一块藏着的新画布，开的时候 `awaitFirstFrame`
     只是开始认帧，第一帧真到了才露：格子里是「头像消失 → 底色 → 画面」，与 Android 一致。
     见 `IMVideoRegistry.resetForReopen(owner:)` 的注释。
     */
    public func setMuted(_ cid: String, _ muted: Bool) {
        lock.lock()
        let track = localTracks[cid]
        let toggles = cid == publishedCameraCID && capturePaused != muted
        if toggles { capturePaused = muted }
        let camera = toggles ? capturer : nil
        let synthetic = toggles ? syntheticCapturer : nil
        let front = usingFrontCamera
        let pub = peers?.pub
        lock.unlock()
        track?.isEnabled = !muted
        guard toggles else { return }
        if muted {
            Self.halt(camera, synthetic)
            registry.resetForReopen(owner: imLocalViewKey(cid))
            uplinkVideoStats.sample(pub, phase: "关摄像头")
            return
        }
        registry.awaitFirstFrame(owner: imLocalViewKey(cid))
        uplinkVideoStats.burst(pub)
        synthetic?.startCapture(width: profile.width, height: profile.height, fps: profile.frameRate)
        guard let camera else { return }
        do {
            let choice = try Self.captureChoice(front: front, profile: profile)
            camera.startCapture(with: choice.device, format: choice.format, fps: choice.fps)
        } catch {
            IMRTCLog.warn("重新打开摄像头失败", ["err": String(describing: error)])
        }
    }

    /// setSpeakerOn 切扬声器。走 `RTCAudioSession` 而不是直接碰 `AVAudioSession`——
    /// libwebrtc 自己也在管这个 session，绕开它会两边打架。
    public func setSpeakerOn(_ on: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            IMRTCLog.warn("切换扬声器失败", ["on": String(on), "err": String(describing: error)])
        }
    }

    /**
     switchCamera 前后摄像头翻转。

     **不重新协商**：`RTCCameraVideoCapturer` 换个 device 重新 `startCapture` 就行，
     轨道对象、`track_id` 与 `cid` 一个都不变，服务端与对端不需要知道这件事。
     只有一个摄像头（或另一个被别的程序占着）时保持原样——别为了翻转把通话弄断。
     摄像头关着（采集停着）时不翻：翻转会重新 `startCapture`，等于替用户把摄像头打开了。
    */
    public func switchCamera() async {
        lock.lock()
        let generation = captureGeneration
        let capturer = self.capturer
        let paused = capturePaused
        let wanted: AVCaptureDevice.Position = usingFrontCamera ? .back : .front
        lock.unlock()
        guard let capturer else { return }
        guard !paused else {
            IMRTCLog.warn("摄像头关着，不翻转", [:])
            return
        }
        guard RTCCameraVideoCapturer.captureDevices().contains(where: { $0.position == wanted }) else {
            IMRTCLog.warn("没有另一个摄像头可翻", ["wanted": wanted == .front ? "front" : "back"])
            return
        }
        lock.lock(); usingFrontCamera.toggle(); lock.unlock()
        do {
            try await startCapture(capturer)
            // 翻到一半通话结束了：把刚起来的采集停掉，别让摄像头留在那儿亮着。
            try assertLive(generation) { Self.halt(capturer, nil) }
        } catch {
            // 翻转失败就翻回去：宁可保持原来那个摄像头，也不要一片黑。
            lock.lock(); usingFrontCamera.toggle(); lock.unlock()
            IMRTCLog.warn("翻转摄像头失败", ["err": String(describing: error)])
        }
    }

    /// 见协议里的说明。**读也要进锁**：翻转发生在界面那条线程，这里被状态机线程读。
    public var isUsingFrontCamera: Bool {
        lock.lock(); defer { lock.unlock() }
        return usingFrontCamera
    }

    public func attachRemoteView(_ uid: String, _ view: AnyObject?) {
        // 线程由登记表自己管（它整张表只在主线程上动）。
        registry.attach(owner: uid, to: view as? UIView)
    }

    /**
     attachLocalView 把本端某条轨道挂到视图上做预览；传 nil 只从容器上摘下来，
     视图本身与它的 sink **不销毁**（整通电话复用，见 `IMVideoRegistry.attach(owner:to:)`）。

     **走的是同一张登记表**（键加 `:local:` 前缀），不是另起一套。
     原先这里每调一次就 `addSubview` 一个新的 `RTCMTLVideoView`，
     而 Kit 每次界面状态变化都会重挂一遍——格子里叠了一摞渲染视图，
     且传 nil 时什么都不做，卸载不掉。

     关摄像头再开摄像头走的就是这条路（`view` 非 nil 再传一次），
     不是 `stopLocalPreview`——真正的释放只发生在挂断 / 进房前的
     `stopLocalPreview()`（那两处调用 `registry.remove`/`removeAll`）。
    */
    public func attachLocalView(_ cid: String, _ view: AnyObject?) {
        let key = imLocalViewKey(cid)
        guard let container = view as? UIView else {
            registry.attach(owner: key, to: nil)
            return
        }
        lock.lock()
        let track = localTracks[cid] as? RTCVideoTrack
        lock.unlock()
        if let track { registry.addTrack(cid, track, owner: key) }
        registry.attach(owner: key, to: container)
    }

    /**
     claimRemoteTracks 告诉媒体层「哪条 track_id 是谁的」。

     媒体层自己**无从知道**这件事：`didAdd rtpReceiver` 只带 track_id，
     归属写在信令帧 `room.track_published` 里。两者谁先到都可能，
     所以轨道先按 track_id 收下，归属到了再认领。
    */
    public func claimRemoteTracks(_ owners: [String: String]) {
        for (trackID, uid) in owners { registry.claim(trackID, owner: uid) }
    }

    /// close 收掉这一轮的媒体面。**一次锁里全部摘干净**，再在锁外面真正关。
    ///
    /// 代际 +1 是给还挂在 await 上的采集流程看的：它们醒来会发现自己这一轮已经作废
    /// （见 `captureGeneration`），从而不会把摄像头留在那儿亮着。
    public func close() {
        lock.lock()
        captureGeneration += 1
        let camera = capturer
        let synthetic = syntheticCapturer
        // **关掉就丢掉**：RTCPeerConnection 不能复用，下一通电话由 ensurePeers 现造一对。
        let oldPeers = peers
        capturer = nil
        syntheticCapturer = nil
        videoSource = nil
        previewTrack = nil
        publishedCameraCID = nil
        capturePaused = false
        localTracks = [:]
        peers = nil
        lock.unlock()

        // 真正的关闭动作放在锁外面：不把 libwebrtc 的调用圈进自己的锁里。
        Self.halt(camera, synthetic)
        registry.removeAll()
        uplinkVideoStats.cancel()
        oldPeers?.close()
    }

    // MARK: - 内部

    /// assertLive 确认这一轮采集还没被作废（`close()` / `stopLocalPreview()`）；作废了就执行 cleanup 再抛错。
    private func assertLive(_ generation: Int, cleanup: () -> Void = {}) throws {
        lock.lock()
        let stale = generation != captureGeneration
        lock.unlock()
        guard stale else { return }
        cleanup()
        throw IMRTCError(.invalidState, "采集还没起来就作废了（通话结束，或关了摄像头）")
    }

    private func remember(cid: String, track: RTCMediaStreamTrack) {
        lock.lock()
        localTracks[cid] = track
        lock.unlock()
    }

    /// handleRemoteTrack 处理一条下行轨道。
    ///
    /// **track_id 就是协议里的 track_id**：订阅侧 SDP 的 msid 即此值（协议 §2.5 表）。
    private func handleRemoteTrack(_ track: RTCMediaStreamTrack) {
        let trackID = track.trackId
        events.onRemoteTrack?(trackID)
        guard let video = track as? RTCVideoTrack else { return }
        // **归属这时候通常还不知道**（信令帧可能后到），先按 track_id 收着，
        // 等 claimRemoteTracks 认领。这里原先直接把 track_id 当 uid 挂进去，
        // 而挂载侧传的是真 uid，两把钥匙永远对不上——协商全通但一格画面都没有。
        registry.addTrack(trackID, video, owner: "")
        // 第一帧探针。**判据是真的出帧**，不是协商完成——提前抛等于让 UI 撤了 loading 去露黑屏。
        let probe = IMFirstFrameProbe { [weak self] _, _, _ in
            self?.events.onFirstVideoFrame?(trackID)
        }
        video.add(probe)
    }

    /// startCapture 按当前朝向起摄像头（格式怎么挑见 `captureChoice`）。
    private func startCapture(_ capturer: RTCCameraVideoCapturer) async throws {
        lock.lock()
        let front = usingFrontCamera
        lock.unlock()
        let choice = try Self.captureChoice(front: front, profile: profile)
        try await capturer.startCapture(with: choice.device, format: choice.format, fps: choice.fps)
    }
}
#endif
