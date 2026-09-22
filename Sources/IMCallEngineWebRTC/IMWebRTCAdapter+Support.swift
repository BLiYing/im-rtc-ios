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
    /**
     makeCameraCapturer 建摄像头采集器，**自己给一个 `AVCaptureSession`**。

     不能用 `RTCCameraVideoCapturer(delegate:)`：现在这个预编译包（webrtc-sdk，2026-09-18 换）
     的 `createCaptureSession` 与上游不一样——**支持多摄的机型上它返回一个进程内静态共享的
     `AVCaptureMultiCamSession`**，而上游是每个采集器一个普通 `AVCaptureSession`。

     真机上的后果（iPhone 17 Pro Max 实测）：采集会话起不来，
     `AVCaptureSessionRuntimeError -11873 "Cannot Record"`，`isRunning` 恒为 false，
     于是本端预览恒 0x0、上行 0 帧，**而 `startCapture` 不报错**。
     多摄会话要用应用自己的 `AVAudioSession`，上游那句 `usesApplicationAudioSession = NO`
     对它不作数；摄像头又比音频会话配置早（响铃期开预览时音频会话还是默认类目，
     故意不配，见 `IMWebRTCAdapter+AudioSession.swift` 头部），于是"不允许录制"。

     **不能靠提前配音频会话绕过**——那会把回铃音掐断，正是 2026-09-16 修掉的毛病。
     共享会话还有第二个毛病：每个新采集器都往同一个会话上加 output，
     真机日志里第二通电话就看到 `outputs=2`。

     所以走 fork 新增的 `initWithDelegate:captureSession:`（上游没有这个入口，
     它加出来就是给应用自带会话用的），等于把上游那套「一采集器一会话」拿回来。
     */
    static func makeCameraCapturer(
        delegate: RTCVideoCapturerDelegate
    ) -> RTCCameraVideoCapturer {
        RTCCameraVideoCapturer(delegate: delegate, captureSession: AVCaptureSession())
    }

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
    /// 采集会话上**实际接着**的那颗摄像头朝向。会话上没有输入（或输入不是摄像头）时为 nil。
    static func inputPosition(of camera: RTCCameraVideoCapturer) -> AVCaptureDevice.Position? {
        camera.captureSession.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.position }.first
    }

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
        applyCallAudioCategory(why: "首次配置")
    }

    /**
     applyCallAudioCategory 把会话切成通话态，**并把结果回读出来**。

     原先只有「失败了记一条」，而 2026-09-18 真机上的失败**根本不报错**：
     `上行音频采样` 抓到会话在毫秒之间从 `PlayAndRecord/VoiceChat/inputs=1`
     退回系统默认的 `SoloAmbient/Default/inputs=0`，采集侧
     `totalSamplesDuration=0`（一个采样都没录到），八秒后
     `overrideOutputAudioPort` 回 `-50`（category 不对时正是这个码）。
     两个方向都没声音，而日志里一个 WARN 都没有。

     所以这里三件事一起做：**量耗时**（同一天两通都在这一步前后卡了 11~18 秒，
     是不是卡在 `setActive` 上此前分不出来）、**回读**（设完真的是那个 category 吗）、
     **说清楚是哪一次**（首次配置 / 被打断后补回 / 媒体服务重置后重建）。
     */
    func applyCallAudioCategory(why: String) {
        // 我们配会话时顺手把 WebRTC 那份也钉一遍：两份不一致，ADM 开麦时就会把我们配的覆盖掉。
        IMWebRTCAudioConfiguration.install()
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let startedNS = DispatchTime.now().uptimeNanoseconds
        // **`isActive` 是判这一刀有没有真做的关键**：为 YES 时 `RTCAudioSession.setActive(true)`
        // 只加计数、不碰底层会话（见 `releaseAudioSession`），elapsed 会是 2~3 ms，路由不会重新协商。
        let wasActive = session.isActive
        var failure: String?
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
            // 成功一次记一笔，`close()` 按这个数还回去；见 `audioActivations`。
            lock.lock()
            audioActivations += 1
            lock.unlock()
        } catch {
            // 配不上不该让通话直接失败：多数情况下仍能出声，只是路由不理想。
            failure = String(describing: error)
        }
        let elapsedMS = (DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
        let av = AVAudioSession.sharedInstance()
        let landed = av.category == .playAndRecord
        var fields = [
            "why": why,
            "elapsed_ms": String(elapsedMS),
            "rtc_was_active": String(wasActive),
            "rtc_active": String(session.isActive),
            "category": av.category.rawValue,
            "mode": av.mode.rawValue,
            "inputs": String(av.currentRoute.inputs.count),
            // 会话刚配好这一刻的可选路由清单：路由面板的数据源，见 imDescribeAudioPorts。
            // 光靠 routeChangeNotification 看不到这一刻——没插拔就不会有那条通知。
            "available_inputs": imDescribeAudioPorts(av.availableInputs),
            "outputs": av.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","),
        ]
        let webrtc = IMWebRTCAudioConfiguration.current()
        fields["webrtc_config"] = "\(webrtc.category)/\(webrtc.mode)"
        if let failure { fields["err"] = failure }
        // **回读对不上比抛错更值得喊**：抛错至少还有个错误码，回读对不上是纯静默。
        if failure != nil || !landed {
            IMRTCLog.warn("音频会话没配成通话态", fields)
        } else {
            IMRTCLog.info("音频会话已配成通话态", fields)
        }
    }

    /**
     releaseAudioSession 媒体停止时把会话放开，与 `applyCallAudioCategory` 成对：
     那边每成功 `setActive(true)` 一次，这里就 `setActive(false)` 一次。

     # 「第一通有声、挂断再打就哑」的根因（2026-09-22，真机 8 轮 100% 复现）

     `RTCAudioSession` 的激活是**引用计数 + 一个 `isActive` 标记**，`setActive:` 的规则
     （从 WebRTC.framework 反汇编核实，这一版与上游略有出入）：
     - `setActive(true)`：`isActive == NO` 才真调底层 `AVAudioSession.setActive(true)`，
       否则**只加计数**——2~3 ms 就返回，路由不会重新协商；
     - `setActive(false)`：只有 `isActive == YES && count == 1` 才真关底层，并把 `isActive` 清掉；
       **其余情形只减计数、`isActive` 保持 YES**。

     旧代码为了传 `notifyOthersOnDeactivation`，走的是 `session.session.setActive(false, options:)`
     ——**绕过了 `RTCAudioSession` 直接关底层**。后果：底层会话真关了，`RTCAudioSession`
     仍记着 `count=1 / isActive=YES`（我们那一次激活从没还回去；libwebrtc 自己那一次 2→1 是配平的）。
     下一通 `setActive(true)` 一看 `isActive=YES` → 只加计数（日志 `Number of current activations: 2`、
     `elapsed_ms=3`），底层会话**根本没被激活**：`currentRoute` 看到的是系统闲置态
     （蓝牙 `A2DP`、`inputs=0`），libwebrtc `setPreferredInputNumberOfChannels` 报 `-50`，
     `InitRecording: InitPlayOrRecord failed`，音频单元起不来，两个方向同时无声。
     没接蓝牙时音频单元启动会隐式激活会话、用内置麦，所以这条从 09-16 起一直没暴露。

     而这一天前几轮盯着 `setPreferredInput(nil)`、开场钉路由、改 category 的修法全是在这条
     错误前提上打转——那些现象（A2DP、`inputs=0`）都是「会话没激活」的**表象**，不是原因。

     # 现在的做法

     全部经 `RTCAudioSession.setActive(_:)`，**不再碰 `session.session`**。它自己在真关底层时
     就会传 `notifyOthersOnDeactivation`（头文件明写），旧注释说「没有带 options 的重载所以要绕」
     是误读。次序无所谓：libwebrtc 的 ADM 与我们谁后走，谁那一次 `count==1` 就真关底层——
     `isActive` 在此之前一直是 YES。回读 `rtc_active` 是为下一次真机排查留的把手：
     释放完仍为 true 就说明还有人欠着一次没还。

     **这里仍然绝不能撤输入偏好**（`setPreferredInput(nil)`）：蓝牙连着时那会把会话往 A2DP 推。
     跨通话状态不归调用方管，只在 category/mode 上表达意图，「选哪条」交给系统协商；
     用户手动选路由那条路径要保证 `setPreferredInput` 永远不传 nil
     （见 `IMWebRTCAdapter+AudioRoute.swift` 的 `inputPort(for:)`）。
     */
    static func releaseAudioSession(activations: Int) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        var failure: String?
        // 只还欠着的那几次：`setActive(true)` 一次都没成功过就一次也别减，计数减到负数会被 libwebrtc 断言。
        for _ in 0..<activations {
            do {
                try session.setActive(false)
            } catch {
                // 放不开不该往上抛：通话已经结束了，顶多是路由状态留了一会儿没归位。
                failure = String(describing: error)
            }
        }
        var fields = [
            "activations": String(activations),
            "rtc_active": String(session.isActive),
            "outputs": AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
                .joined(separator: ","),
        ]
        if let failure { fields["err"] = failure }
        if failure != nil || session.isActive {
            IMRTCLog.warn("音频会话释放后仍是激活态", fields)
        } else {
            IMRTCLog.info("音频会话已释放", fields)
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
