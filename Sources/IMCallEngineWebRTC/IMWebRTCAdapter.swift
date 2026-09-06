#if canImport(WebRTC) && canImport(UIKit)
import AVFoundation
import Foundation
import UIKit
import WebRTC
import IMCallEngine

/*
 `IMMediaAdapter` 的 libwebrtc 实现。**Engine 里唯一碰 WebRTC 的地方。**

 换媒体实现（或做 P2P 隐私模式）时只动这个 target，状态机与信令一行不用改。
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
    /// 远端轨道的 track_id → uid 由上层告知；这里只按 track_id 记账。
    private let lock = NSLock()

    /// 采集画质档位。见 `IMVideoProfile`：**策略归宿主**，不是服务端下发的。
    private let profile: IMVideoProfile

    /// - Parameter videoProfile: 画质档位，默认 720p。
    @objc public init(videoProfile: IMVideoProfile = .default) {
        self.profile = videoProfile
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
     acquireCamera 拿摄像头轨道挂到 pub 上。

     `simulcast` 为真时**推三层**（rid = h/m/l，协议 §3.5）。三层的
     `scaleResolutionDownBy` 是 1/2/4，服务端按订阅侧报的层上界与带宽估计选一层转发。
     */
    /**
     probeMicrophone 只问系统要麦克风权限，不开采集。

     系统框由 `AVCaptureDevice.requestAccess` 弹；已授权时它立刻回 true、不弹框。
     被拒映射成 2001——Kit 钉着这个码决定是「整通取消」还是「降级继续」（交互稿 §02）。
     */
    public func probeMicrophone() async throws {
        try await Self.ensureAccess(.audio, what: "麦克风")
    }

    /// ensureAccess 把系统权限状态收敛成结构化错误：拒绝 → 2001。
    private static func ensureAccess(_ media: AVMediaType, what: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized:
            return
        case .notDetermined:
            // 这一步会弹系统框，只弹一次；之后系统记住选择。
            guard await AVCaptureDevice.requestAccess(for: media) else {
                throw IMRTCError(.devicePermissionDenied, "\(what)权限被拒")
            }
        default:
            throw IMRTCError(.devicePermissionDenied, "\(what)权限被拒")
        }
    }

    /// startLocalPreview 只起采集，不挂 transceiver。
    public func startLocalPreview() async throws -> IMLocalTrackInfo {
        if let existing = previewTrack { return existing }
        // 先问权限再开设备：没这一步的话 libwebrtc 的采集器在被拒时只是静默地不出画面。
        try await Self.ensureAccess(.video, what: "摄像头")
        let cid = "cam-\(UUID().uuidString.prefix(8))"
        let source = ensurePeers().factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let track = ensurePeers().factory.videoTrack(with: source, trackId: cid)
        self.videoSource = source
        self.capturer = capturer
        try await startCapture(capturer)
        remember(cid: cid, track: track)
        let info = IMLocalTrackInfo(cid: cid, kind: "video", source: "camera")
        previewTrack = info
        return info
    }

    public func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo {
        // **复用预览那条轨道**：拨出时已经开过摄像头了，再开一次会抢设备。
        let info = try await startLocalPreview()
        let cid = info.cid
        lock.lock()
        let track = localTracks[cid] as? RTCVideoTrack
        lock.unlock()
        guard let track else {
            throw IMRTCError(.deviceNotFound, "摄像头轨道丢失")
        }
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
        ensurePeers().pub.addTransceiver(with: track, init: transceiverInit)
        return info
    }

    /// createPubOffer 生成上行 offer。**pub 的 offerer 恒为本端**（协议 §3.3）。
    public func createPubOffer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await ensurePeers().pub.offer(for: constraints)
        try await ensurePeers().pub.setLocalDescription(offer)
        return offer.sdp
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

    /// setMuted 停/复发包。**不是 unpublish**：轨道与协商都保留。
    public func setMuted(_ cid: String, _ muted: Bool) {
        lock.lock()
        let track = localTracks[cid]
        lock.unlock()
        track?.isEnabled = !muted
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
    */
    public func switchCamera() async {
        guard let capturer else { return }
        let wanted: AVCaptureDevice.Position = usingFrontCamera ? .back : .front
        guard RTCCameraVideoCapturer.captureDevices().contains(where: { $0.position == wanted }) else {
            IMRTCLog.warn("没有另一个摄像头可翻", ["wanted": wanted == .front ? "front" : "back"])
            return
        }
        usingFrontCamera.toggle()
        do {
            try await startCapture(capturer)
        } catch {
            // 翻转失败就翻回去：宁可保持原来那个摄像头，也不要一片黑。
            usingFrontCamera.toggle()
            IMRTCLog.warn("翻转摄像头失败", ["err": String(describing: error)])
        }
    }

    public func attachRemoteView(_ uid: String, _ view: AnyObject?) {
        // 线程由登记表自己管（它整张表只在主线程上动）。
        registry.attach(owner: uid, to: view as? UIView)
    }

    /**
     attachLocalView 把本端某条轨道挂到视图上做预览；传 nil 卸载。

     **走的是同一张登记表**（键加 `:local:` 前缀），不是另起一套。
     原先这里每调一次就 `addSubview` 一个新的 `RTCMTLVideoView`，
     而 Kit 每次界面状态变化都会重挂一遍——格子里叠了一摞渲染视图，
     且传 nil 时什么都不做，卸载不掉。
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

    public func close() {
        capturer?.stopCapture()
        capturer = nil
        videoSource = nil
        previewTrack = nil
        lock.lock()
        localTracks = [:]
        lock.unlock()
        registry.removeAll()
        // **关掉就丢掉**：RTCPeerConnection 不能复用，下一通电话由 ensurePeers 现造一对。
        lock.lock()
        let old = peers
        peers = nil
        lock.unlock()
        old?.close()
    }

    // MARK: - 内部

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
        let probe = IMFirstFrameProbe { [weak self] in
            self?.events.onFirstVideoFrame?(trackID)
        }
        video.add(probe)
    }

    /// startCapture 起摄像头，挑**前置 + 最接近档位分辨率**的格式。
    ///
    /// 挑「最接近」而不是「必须等于」：设备支持的格式表是离散的，
    /// 要求精确匹配会在某些机型上一个格式都挑不出来，通话直接打不出去。
    private func startCapture(_ capturer: RTCCameraVideoCapturer) async throws {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let wantedPosition: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let device = devices.first(where: { $0.position == wantedPosition }) ?? devices.first else {
            throw IMRTCError(.deviceNotFound, "没有可用的摄像头")
        }
        let wanted = profile.width
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.min(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return abs(Int(l.width) - wanted) < abs(Int(r.width) - wanted)
        }) else {
            throw IMRTCError(.deviceNotFound, "摄像头没有可用格式")
        }
        let fps = format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate).max().map { Int(min($0, Double(profile.frameRate))) }
            ?? profile.frameRate
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        IMRTCLog.info("摄像头已开", [
            "profile": profile.name, "width": String(size.width),
            "height": String(size.height), "fps": String(fps),
        ])
        try await capturer.startCapture(with: device, format: format, fps: fps)
    }

    /**
     configureAudioSession 配音频会话。

     `.voiceChat` 模式会打开**回声消除与自动增益**——不配的话自己会听到自己的回声，
     而那听起来像"对方设备有问题"，很容易查错方向。
     */
    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            // 配不上不该让通话直接失败：多数情况下仍能出声，只是路由不理想。
            IMRTCLog.warn("音频会话配置失败", ["err": String(describing: error)])
        }
    }

    /// simulcastEncodings 是 simulcast 三层（协议 §3.5：rid 为 h/m/l），码率跟着档位走。
    private static func simulcastEncodings(_ profile: IMVideoProfile) -> [RTCRtpEncodingParameters] {
        profile.simulcastLayers.map { layer in
            let encoding = RTCRtpEncodingParameters()
            encoding.rid = layer.rid
            encoding.isActive = true
            encoding.scaleResolutionDownBy = NSNumber(value: layer.scaleDownBy)
            encoding.maxBitrateBps = NSNumber(value: layer.bitrateBps)
            return encoding
        }
    }

    private static func stateName(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }
}
#endif

