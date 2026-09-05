#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import UIKit
import WebRTC
import IMCallEngine

/*
 `IMMediaAdapter` 的 libwebrtc 实现。**Engine 里唯一碰 WebRTC 的地方。**

 换媒体实现（或做 P2P 隐私模式）时只动这个 target，状态机与信令一行不用改。
 */
public final class IMWebRTCAdapter: NSObject, IMMediaAdapter, @unchecked Sendable {

    private let pcs = IMPeerConnections()
    private let registry = IMVideoRegistry()
    private var events = IMMediaAdapterEvents()

    /// 本端轨道，按 cid 索引。
    private var localTracks: [String: RTCMediaStreamTrack] = [:]
    /// 摄像头采集器。**必须持有**：不留引用的话它会被释放，画面直接停掉。
    private var capturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    /// 远端轨道的 track_id → uid 由上层告知；这里只按 track_id 记账。
    private let lock = NSLock()

    public override init() {
        super.init()
    }

    // MARK: - IMMediaAdapter

    public func open(_ events: IMMediaAdapterEvents) {
        self.events = events
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
        configureAudioSession()
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
        let source = pcs.factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil))
        let track = pcs.factory.audioTrack(with: source, trackId: cid)
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["im-rtc"]
        pcs.pub.addTransceiver(with: track, init: transceiverInit)
        remember(cid: cid, track: track)
        return IMLocalTrackInfo(cid: cid, kind: "audio", source: "microphone")
    }

    /**
     acquireCamera 拿摄像头轨道挂到 pub 上。

     `simulcast` 为真时**推三层**（rid = h/m/l，协议 §3.5）。三层的
     `scaleResolutionDownBy` 是 1/2/4，服务端按订阅侧报的层上界与带宽估计选一层转发。
     */
    public func acquireCamera(simulcast: Bool) async throws -> IMLocalTrackInfo {
        let cid = "cam-\(UUID().uuidString.prefix(8))"
        let source = pcs.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let track = pcs.factory.videoTrack(with: source, trackId: cid)

        self.videoSource = source
        self.capturer = capturer
        try await startCapture(capturer)

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["im-rtc"]
        if simulcast {
            transceiverInit.sendEncodings = Self.simulcastEncodings()
        }
        pcs.pub.addTransceiver(with: track, init: transceiverInit)
        remember(cid: cid, track: track)
        return IMLocalTrackInfo(cid: cid, kind: "video", source: "camera")
    }

    /// createPubOffer 生成上行 offer。**pub 的 offerer 恒为本端**（协议 §3.3）。
    public func createPubOffer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await pcs.pub.offer(for: constraints)
        try await pcs.pub.setLocalDescription(offer)
        return offer.sdp
    }

    public func applyPubAnswer(_ sdp: String) async throws {
        try await pcs.setRemoteDescription(
            RTCSessionDescription(type: .answer, sdp: sdp), for: .pub)
    }

    /// answerSubOffer 应答服务端下发的下行 offer。**sub 的 offerer 恒为服务端**。
    public func answerSubOffer(_ sdp: String) async throws -> String {
        try await pcs.setRemoteDescription(
            RTCSessionDescription(type: .offer, sdp: sdp), for: .sub)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer = try await pcs.sub.answer(for: constraints)
        try await pcs.sub.setLocalDescription(answer)
        return answer.sdp
    }

    public func addRemoteCandidate(_ pc: IMPCRole, _ candidate: IMICECandidate) async throws {
        try await pcs.addRemoteCandidate(
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

    public func attachRemoteView(_ uid: String, _ view: AnyObject?) {
        // 视图操作必须在主线程。**用 async 不用 sync**（CONVENTIONS §5 禁止 main.sync）。
        DispatchQueue.main.async { [weak self] in
            self?.registry.attach(uid: uid, to: view as? UIView)
        }
    }

    public func attachLocalView(_ cid: String, _ view: AnyObject?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let track = self.localTracks[cid] as? RTCVideoTrack
            self.lock.unlock()
            guard let track, let container = view as? UIView else { return }
            let renderView = RTCMTLVideoView(frame: container.bounds)
            renderView.videoContentMode = .scaleAspectFill
            renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(renderView)
            track.add(renderView)
        }
    }

    public func close() {
        capturer?.stopCapture()
        capturer = nil
        videoSource = nil
        lock.lock()
        localTracks = [:]
        lock.unlock()
        registry.removeAll()
        pcs.close()
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
        // 第一帧探针。**判据是真的出帧**，不是协商完成——提前抛等于让 UI 撤了 loading 去露黑屏。
        let probe = IMFirstFrameProbe { [weak self] in
            self?.events.onFirstVideoFrame?(trackID)
        }
        video.add(probe)
        registry.bind(uid: trackID, track: video)
    }

    /// startCapture 起摄像头。挑**前置 + 最接近 720p 的格式**（草图 §02 的默认分辨率）。
    private func startCapture(_ capturer: RTCCameraVideoCapturer) async throws {
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
            throw IMRTCError(.deviceNotFound, "没有可用的摄像头")
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.min(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return abs(Int(l.width) - 1280) < abs(Int(r.width) - 1280)
        }) else {
            throw IMRTCError(.deviceNotFound, "摄像头没有可用格式")
        }
        let fps = format.videoSupportedFrameRateRanges
            .map(\.maxFrameRate).max().map { Int(min($0, 30)) } ?? 30
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

    /// simulcastEncodings 是 simulcast 三层（协议 §3.5：rid 为 h/m/l）。
    private static func simulcastEncodings() -> [RTCRtpEncodingParameters] {
        [("h", 1.0, 1_700_000), ("m", 2.0, 500_000), ("l", 4.0, 150_000)]
            .map { rid, scale, bitrate in
                let encoding = RTCRtpEncodingParameters()
                encoding.rid = rid
                encoding.isActive = true
                encoding.scaleResolutionDownBy = NSNumber(value: scale)
                encoding.maxBitrateBps = NSNumber(value: bitrate)
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

