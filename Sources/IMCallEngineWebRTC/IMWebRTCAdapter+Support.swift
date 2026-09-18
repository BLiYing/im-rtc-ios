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
        let capturer = RTCCameraVideoCapturer(delegate: delegate, captureSession: AVCaptureSession())
        // **必须在构造之后设**，理由见 `shieldAudioSession(of:)`：构造函数会把它改回去。
        shieldAudioSession(of: capturer.captureSession)
        return capturer
    }

    /**
     shieldAudioSession 不许摄像头采集会话碰 App 的音频会话。**视频通话双向无声的根因（2026-09-18）。**

     # 现象

     视频通话里，接通那一刻我们把音频会话配成 `.playAndRecord/.voiceChat`，约 150 ms 后
     它被打回系统默认的 `SoloAmbient`、输入口变 0；补回去，再被打回，一秒里拉锯六轮。
     libwebrtc 的音频单元在第一下就被掀翻，之后 `packetsSent` / `totalSamplesDuration`
     三十秒全是 0——**收发两个方向同时没声音**（19:47 首装后连打三通，通通如此）。
     纯音频通话（不开摄像头）同一版代码 30 秒 `packetsSent` 涨到 1065，会话从没被动过。

     # 谁干的

     反汇编这个预编译包（webrtc-sdk 150.7871.01）排除了所有别的嫌疑：
     - 包里唯一引用 `SoloAmbient` 的地方是 `audio_engine_device.mm` 里一串
       `isEqualToString:` **比较**，不是设置；
     - 包里所有改类目 / 激活状态的调用点全在 `RTCAudioSession(+Configuration)` 与
       `audio_device_ios.mm`，设的都是 PlayAndRecord 那套 `webRTCConfiguration`；
     - 我们自己的代码里只有 `applyCallAudioCategory()` 一处设类目，设的也是 PlayAndRecord。

     剩下的只有 AVFoundation 自己。`RTCCameraVideoCapturer` 的 `setupCaptureSession:`
     （`initWithDelegate:captureSession:` 一定会走它，**注入的 session 也不例外**）
     把 `usesApplicationAudioSession` 设成 **NO**，而 `automaticallyConfiguresApplicationAudioSession`
     只在它自建 session 的 `createCaptureSession` 里设成 NO，对注入的 session 从没碰过，
     留在系统默认的 **YES**。于是我们的采集会话跑在这样的组合上：
     **用一个私有音频会话 + AVFoundation 自动配置**。Apple 头文件对前者的原话是
     「pre-iOS 7 behavior … can lead to unwanted interruptions when interacting with the
     application's audio session」——两个写手各自"恢复"自己想要的配置，就是那一秒的拉锯。

     # 为什么上一版（`4fa128a`）没用

     它在**构造之前**把旗标设在了 session 上，构造函数里的 `setupCaptureSession:`
     随手就把 `usesApplicationAudioSession` 翻回 NO。所以要在构造**之后**设，
     并且起采集前再设一遍——包里两个 setter 都在，防它哪天在别处再改。

     `usesApplicationAudioSession = true`：共用 App 这一个会话（Apple：allowing simultaneous
     play back and recording without unwanted interruptions）。
     `automaticallyConfiguresApplicationAudioSession = false`：用可以，**一个属性都不许改**。
     这也正是这个 fork 给它自建的多摄 session 设的值。纯视频采集没有音频输入，
     响铃期会话还是默认类目也照样跑得起来。

     **没有真机直接看见 AVFoundation 写 SoloAmbient 那一笔**——它在框架内部，看不见。
     以上是把每一个别的写手都排除之后剩下的那个，外加它的行为与 Apple 的文档、
     与"只在视频通话里犯"的分布都对得上。验收判据：`通话中音频会话被打回非通话类目`
     这条 WARN 在视频通话里不再出现，`上行音频采样` 的 `packetsSent` 在涨。
     */
    static func shieldAudioSession(of session: AVCaptureSession) {
        session.usesApplicationAudioSession = true
        session.automaticallyConfiguresApplicationAudioSession = false
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
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let startedNS = DispatchTime.now().uptimeNanoseconds
        var failure: String?
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            // 配不上不该让通话直接失败：多数情况下仍能出声，只是路由不理想。
            failure = String(describing: error)
        }
        /*
         **接管音频单元的开关（2026-09-18）。**

         `useManualAudio = NO`（默认）时，音频单元什么时候起、什么时候拆全由 libwebrtc
         自己判断，我们只能眼看着。真机 19:47 三通群视频复现出来的就是这个：
         我们把类目设成 `.playAndRecord`，约 150 ms 后会话被打回 `SoloAmbient`，
         兜底再设回来——**类目补回来了，`packetsSent` 却始终是 0**，
         三十秒 `totalSamplesDuration=0`。音频单元在那一下已经被拆掉，
         而它不会因为类目恢复就自己重建。擦桌子救不了灶。

         `useManualAudio = YES` 之后 `isAudioEnabled` 才生效，它正是拆/建音频单元的开关
         （头文件原话：设 NO 会 stop and uninitialize，设 YES 会在需要时 initialize and start）。
         于是「被打翻之后重新点火」这件事才有手柄可抓，见 `reassertCallAudioCategory`。

         **头文件还说明了这个属性当初为什么存在**：AVPlayer 正在放音时初始化 VoIP 音频单元，
         会把那路音频掐断或压低。我们的回铃音就是一个 `AVAudioPlayer`。

         **这不是根因修复，是安全网。** 根因（摄像头采集会话跑在私有音频会话 + AVFoundation
         自动配置上，与我们抢会话）在 `shieldAudioSession(of:)`；这里只保证万一还有谁把会话
         掀翻，`reassertCallAudioCategory` 有手柄把音频单元重新点起来。另注：包里的
         `audio_engine_device.mm`（AVAudioEngine 那种 ADM）不走 `RTCAudioSession` 的
         begin/end，`useManualAudio` 对它是否生效没有证据，默认工厂用的是哪种 ADM 也没查出来。
        */
        session.useManualAudio = true
        session.isAudioEnabled = true
        let elapsedMS = (DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
        let av = AVAudioSession.sharedInstance()
        let landed = av.category == .playAndRecord
        var fields = [
            "why": why,
            "elapsed_ms": String(elapsedMS),
            "category": av.category.rawValue,
            "mode": av.mode.rawValue,
            "inputs": String(av.currentRoute.inputs.count),
        ]
        fields["audio_unit_enabled"] = String(session.isAudioEnabled)
        if let failure { fields["err"] = failure }
        // **回读对不上比抛错更值得喊**：抛错至少还有个错误码，回读对不上是纯静默。
        if failure != nil || !landed {
            IMRTCLog.warn("音频会话没配成通话态", fields)
        } else {
            IMRTCLog.info("音频会话已配成通话态", fields)
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
        // 与 `applyCallAudioCategory` 里的 `useManualAudio = true` 成对：先让 libwebrtc
        // 把音频单元拆干净，再放会话。顺序反了的话拆的时候会话已经不是通话态了。
        session.isAudioEnabled = false
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
