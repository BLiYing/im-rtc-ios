#if canImport(WebRTC) && canImport(UIKit)
import AVFoundation
import Foundation
import WebRTC
import IMCallEngine

/*
 `IMWebRTCAdapter` 里**不碰可变状态**的那几件事：权限、挑采集格式、音频会话、simulcast 编码参数。

 拆出来是因为主文件逼近 600 行红线。这里全是 static 或只读入参，不需要进锁——
 加锁的字段一个都不许挪到这里来。
 */

/// 一次摄像头采集用哪个设备、哪个格式、多少帧。
struct IMCaptureChoice {
    let device: AVCaptureDevice
    let format: AVCaptureDevice.Format
    let fps: Int
}

extension IMWebRTCAdapter {

    /// ensureAccess 把系统权限状态收敛成结构化错误：拒绝 → 2001。
    static func ensureAccess(_ media: AVMediaType, what: String) async throws {
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

    /// captureChoice 挑**指定朝向 + 最接近档位分辨率**的格式。
    ///
    /// 挑「最接近」而不是「必须等于」：设备支持的格式表是离散的，
    /// 要求精确匹配会在某些机型上一个格式都挑不出来，通话直接打不出去。
    static func captureChoice(front: Bool, profile: IMVideoProfile) throws -> IMCaptureChoice {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let wantedPosition: AVCaptureDevice.Position = front ? .front : .back
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
        // **只是「挑好了格式」，不是「采集起来了」**。原先这行叫「摄像头已开」，
        // 而它打在 `startCapture` 之前——2026-09-18 换包后采集一帧不出，日志上却写着「已开」，
        // 查了半天才发现这行根本不证明任何事。真正的成败由 `startCapture` 那两行记。
        IMRTCLog.info("摄像头格式已选", [
            "profile": profile.name, "width": String(size.width),
            "height": String(size.height), "fps": String(fps),
            "device": device.localizedName, "position": front ? "front" : "back",
        ])
        return IMCaptureChoice(device: device, format: format, fps: fps)
    }

    /**
     halt 停采集。**特意是个同步函数**：`RTCCameraVideoCapturer` 同时有同步的 `stopCapture()`
     和带回调的那个（Swift 会把后者导成 async），在 async 函数里直接写 `stopCapture()`
     编译器挑的是 async 那个，于是要求 await。放进同步函数里就不会挑错。
     */
    static func halt(_ camera: RTCCameraVideoCapturer?, _ synthetic: IMSyntheticVideoCapturer?) {
        camera?.stopCapture()
        synthetic?.stopCapture()
    }

    /**
     configureAudioSession 配音频会话。

     `.voiceChat` 模式会打开**回声消除与自动增益**——不配的话自己会听到自己的回声，
     而那听起来像"对方设备有问题"，很容易查错方向。

     **调用时机（2026-09-16 改）**：由 `IMWebRTCAdapter.ensureAudioSessionConfigured()`
     在媒体真正启动的那一刻调（`acquireMicrophone()` / `answerSubOffer(_:)` 两个入口，
     为什么是这两个见那个方法所在文件的头部注释），**不再**由 `open(_:)`（= 登录）调。
     `setSpeakerOn(_:)` **不在其中**：它在拨出中就可点，触发配置会掐断正在放的回铃音。旧时机等于「宿主一登录，全 App 音频会话就被接管」——
     没开 `.mixWithOthers` 会直接掐断宿主的背景音乐，响铃期间会话又已经是通话态，
     铃声会走听筒、跟通话音量，等于铃声没做。这与 Android `IMAudioRouter.start()`
     只在拿到 `room_token`（`IMMediaDriver.drive` 的判据）才调用是同一条时间线。
     */
    func configureAudioSession() {
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

    /**
     releaseAudioSession 媒体停止时把会话放开，与 `configureAudioSession()` 成对。

     **必须带 `notifyOthersOnDeactivation`**：不带的话别的 App（宿主自己的背景音乐、
     或者用户切出去正放着的别的音频）不会收到「可以恢复了」的通知，会一直静音到
     它自己下次主动检查。`RTCAudioSession.setActive(_:error:)` 没有带 options 的重载，
     所以这里取它的 `.session`（就是同一个 `AVAudioSession.sharedInstance()`）来传这个参数——
     **仍然在 `lockForConfiguration`/`unlockForConfiguration` 里做**，不是绕开
     `RTCAudioSession` 直接改（那样才会跟 libwebrtc 自己的会话管理打架，见 `setSpeakerOn` 的注释）。
     */
    static func releaseAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // 放不开不该往上抛：通话已经结束了，顶多是路由状态留了一会儿没归位。
            IMRTCLog.warn("音频会话释放失败", ["err": String(describing: error)])
        }
    }

    /// simulcastEncodings 是 simulcast 三层（协议 §3.5：rid 为 h/m/l），码率跟着档位走。
    static func simulcastEncodings(_ profile: IMVideoProfile) -> [RTCRtpEncodingParameters] {
        profile.simulcastLayers.map { layer in
            let encoding = RTCRtpEncodingParameters()
            encoding.rid = layer.rid
            encoding.isActive = true
            encoding.scaleResolutionDownBy = NSNumber(value: layer.scaleDownBy)
            encoding.maxBitrateBps = NSNumber(value: layer.bitrateBps)
            return encoding
        }
    }

    /**
     preferResolutionOverFramerate CPU / 码率吃紧时**掉帧率、不掉分辨率**。

     与 Android `IMUplinkPolicy.preferResolutionOverFramerate` 同一条取舍，理由在那边写全了：
     本产品最吃分辨率的场景是看清画面里的字。iOS 原先没设，libwebrtc 默认 BALANCED——
     分辨率与帧率一起降、再一起升，**每升降一档，对端就换一次解码尺寸**。
     这是 Android 看 iOS 重开摄像头时「画面出来了又刷新一下」的候选原因之一
     （待「上行视频采样」里的 `frameWidth` / `qualityLimitationResolutionChanges` 证实）；
     就算不是，两端取舍不一致本身也说不过去。

     挂上 transceiver 之后、生成 offer 之前设。ObjC 的 setter 不回错误，设没设上看回读。
     */
    static func preferResolutionOverFramerate(_ sender: RTCRtpSender?) {
        guard let sender else {
            IMRTCLog.warn("没拿到视频 sender，降级偏好没设上", [:])
            return
        }
        let wanted = RTCDegradationPreference.maintainResolution.rawValue
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value: wanted)
        sender.parameters = parameters
        if sender.parameters.degradationPreference?.intValue == wanted {
            IMRTCLog.info("编码降级偏好=MAINTAIN_RESOLUTION（宁可掉帧率也保分辨率）", [:])
        } else {
            IMRTCLog.warn("降级偏好没设上，退回 libwebrtc 默认的 BALANCED（分辨率会跟着降）", [:])
        }
    }

    static func stateName(_ state: RTCPeerConnectionState) -> String {
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
