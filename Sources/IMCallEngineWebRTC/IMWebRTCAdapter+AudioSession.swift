#if canImport(WebRTC) && canImport(UIKit)
import Foundation
import AVFoundation
import WebRTC
import IMCallEngine

/*
 音频会话该在哪一刻配置（2026-09-16 新增）。

 旧实现里 `configureAudioSession()`（IMWebRTCAdapter+Support.swift）挂在 `open(_:)`
 上，而 `open(_:)` 由 `IMCallEngine.login(_:)` 调用——等于**宿主一登录，跟有没有
 通话无关，全 App 的音频会话就被接管**成 `.playAndRecord` + `.voiceChat` + active。
 后果两条：一是没开 `.mixWithOthers`，宿主 App 里在放的背景音乐会被直接掐断；
 二是响铃期间会话已经是通话态，铃声会走听筒、跟通话音量走，等于铃声没做。

 iOS 这边没有 Android `IMMediaDriver.drive()`（按 `room_token` 从无到有集中判断
 「媒体真正启动」）那种单一入口——`IMPeerConnections` 是 `ensurePeers()` 按需惰性建的，
 触发点散在 `acquireMicrophone`/`acquireCamera`/`createPubOffer`/`answerSubOffer`
 好几个方法里。**挑了两个具体入口，而不是挂在 `ensurePeers()` 上**：

 1. `acquireMicrophone()`——真正要拿麦克风轨道那一刻，语义上最贴近 Android 那条时间线。
 2. `answerSubOffer(_:)`——**这条是 2026-09-16 复查时补的**：应答下行 offer 由服务端
    推送触发（`RoomStateMachine+Recv.handleSubOffer` 收到 `room.offer(sub)` 当场产出
    `room.answer`），跟 Kit 何时调 `acquireMicrophone` 是两条完全独立的异步路径，
    被叫一进房、对方早已发布时下行 offer 完全可能先到——这正是这次挪动音频会话
    时机**新引入**的窗口（旧实现会话在 `login()` 就配好，不存在这个窗口）。

 **`setSpeakerOn(_:)` 曾经是第三个入口，2026-09-16 又摘掉了**，原因见它自己的注释：
 那颗扬声器按钮在**拨出中（`.outgoing`）就能点**，而那时回铃音正在放——由它去配置
 会话等于当场把回铃音掐断、或者拽到通话路由上，正好把这次要修的毛病又犯一遍。
 现在它只记下选择，等上面两个入口把会话配好再补应用。

 **为什么不挂在 `ensurePeers()` 上**：它是所有媒体路径（含视频）的惰性汇聚点，太宽——
 来电响铃 / 拨出中开摄像头预览（`startLocalPreview`/`startRingingPreviewIfAllowed`）
 也会走到这里，若在这儿配置音频会话，等于又把响铃窗口污染了一遍，正是这次要避免的事。
 音频会话只该被「真正产生或消费音频」的入口触发，纯摄像头预览不该碰它。
 **以后再加媒体入口时**：新入口如果会真正发送或接收音频（而不只是视频/信令），
 就要在它开头加一句 `ensureAudioSessionConfigured()`；只碰视频的入口不用。
 反过来，**「设置类」的入口（改路由、改音量这种）一律不许触发配置**，只许记录意向。

 `close()` 对称收场：配置过的话调 `releaseAudioSession()`（IMWebRTCAdapter+Support.swift），
 没配置过（只起过摄像头预览、mic 从没被 acquire 就被挂断）的情形不动会话。

 拆到独立文件是为了不把 `IMWebRTCAdapter.swift` 顶过 600 行体量红线——这里只放
 「配没配过 / 路由选了什么」这两件事，真正的 `RTCAudioSession` 配置与释放仍在
 `IMWebRTCAdapter+Support.swift` 的 `configureAudioSession()` / `releaseAudioSession()`。
 */
extension IMWebRTCAdapter {
    /// ensureAudioSessionConfigured 把会话配置成通话态，**只做一次**（归 `audioSessionActive`）。
    /// 两个入口都调（`acquireMicrophone` / `answerSubOffer`，各自调用点有注释说明为什么要调，
    /// 本文件头部说明为什么是这两个、为什么不是 `setSpeakerOn` 与 `ensurePeers()`），
    /// 谁先到都行；真正的配置在 `configureAudioSession()`。标记的读改写在 `lock` 里，
    /// 真正调 `configureAudioSession()` 放锁外——不把 `RTCAudioSession` 的锁嵌进来。
    func ensureAudioSessionConfigured() {
        let needsConfig: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if audioSessionActive { return false }
            audioSessionActive = true
            return true
        }()
        guard needsConfig else { return }
        configureAudioSession()
        observeRouteChanges()
        // 会话刚配好，把响铃期间记下的扬声器选择补上（见 setSpeakerOn）。
        lock.lock()
        let wanted = desiredSpeakerOn
        lock.unlock()
        applySpeakerRoute(wanted)
    }

    /// setSpeakerOn 切扬声器。走 `RTCAudioSession` 而不是直接碰 `AVAudioSession`——
    /// libwebrtc 自己也在管这个 session，绕开它会两边打架。
    ///
    /// **2026-09-16 改**：**只记选择，不配置会话**。这颗按钮在拨出中（`.outgoing`）
    /// 就是可点的（`IMCallOverlayViewController.renderControls` 里 `.outgoing` 落在
    /// 带 `speakerButton` 的两个分支上），那时回铃音正放着——若由它触发
    /// `ensureAudioSessionConfigured()`，会当场把会话切成通话态，回铃音被掐断或被拽到
    /// 通话路由上。会话还没配好时记下意向即可，`ensureAudioSessionConfigured()` 配完会补应用；
    /// 这也保住了当初加钩子的那个理由——Kit 在进房即可发布那一刻先同步调本方法、
    /// 再异步走到 `acquireMicrophone()`，意向不会丢。
    ///
    /// **已知限制**：响铃期间点这颗按钮只改「接通后用哪路」，**不改回铃音本身的外放与否**
    /// （回铃音由 Kit 的 `AVAudioPlayer` 放，不归这里管）。按钮的亮灭仍跟着
    /// `state.selfState.speakerOn`，界面不会自相矛盾。
    public func setSpeakerOn(_ on: Bool) {
        let alreadyConfigured: Bool = {
            lock.lock()
            defer { lock.unlock() }
            desiredSpeakerOn = on
            return audioSessionActive
        }()
        guard alreadyConfigured else { return }
        applySpeakerRoute(on)
    }

    /**
     observeRouteChanges：会话配好之后开始听路由变化，`close()` 时摘掉（`stopObservingRouteChanges`）。

     原先没监听：插拔耳机、连断蓝牙，SDK 一概不知道。现在两件事——**记一条日志**（落到哪一档，
     排查「声音从哪出」全靠它），以及**强制外放被系统清掉时补回去**（判据 `imShouldReapplySpeaker`）。
     */
    func observeRouteChanges() {
        stopObservingRouteChanges()
        let center = NotificationCenter.default
        var tokens = [
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
            ) { [weak self] note in
                self?.routeDidChange(note)
            },
        ]
        /*
         **会话被踢掉的两条路，原先一条都没听（2026-09-18 加）。**

         真机上会话在通话中途退回系统默认的 `SoloAmbient`、输入口变 0，
         采集一个采样都没录到，两个方向都没声音——而我们对此一无所知，
         直到八秒后 `overrideOutputAudioPort` 回 `-50` 才留下一条无头无尾的 WARN。

         - `interruptionNotification`：来电、闹钟、Siri 抢走会话。**结束时系统不会替我们恢复**，
           `.shouldResume` 也只是建议，category 要自己再设一遍。
         - `mediaServicesWereResetNotification`：媒体服务守护进程重启。
           **所有音频对象全部作废、会话回到默认 category**，Apple 的要求就是整套重建。
           这一条完全符合上面的现象，但**还没有真机日志证实是它**——先把它变成看得见的。
        */
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            self?.audioSessionInterrupted(note)
        })
        tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            IMRTCLog.warn("媒体服务已重置，音频会话要整套重建", [:])
            self?.reassertCallAudioCategory(why: "媒体服务重置")
        })
        lock.lock()
        sessionObservers = tokens
        lock.unlock()
    }

    func stopObservingRouteChanges() {
        lock.lock()
        let tokens = sessionObservers
        sessionObservers = []
        lock.unlock()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// audioSessionInterrupted 被抢走 / 还回来。**还回来时要自己把 category 设回去**——
    /// 系统只发通知，不负责恢复，而我们的 `.playAndRecord` 一丢就是两个方向都哑。
    private func audioSessionInterrupted(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
        guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            IMRTCLog.warn("音频会话被打断", [:])
        case .ended:
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            IMRTCLog.info("音频会话打断结束", [
                "should_resume": String(AVAudioSession.InterruptionOptions(rawValue: options)
                    .contains(.shouldResume)),
            ])
            reassertCallAudioCategory(why: "打断结束")
        @unknown default:
            break
        }
    }

    /**
     reassertCallAudioCategory 会话被踢掉之后补回通话态，并把响铃期记下的扬声器选择再应用一遍。

     **只在配置过之后才补**：响铃期故意还没配（回铃音要用默认类目，见本文件头部），
     这时补等于把当初要避免的事又做一遍。
     */
    func reassertCallAudioCategory(why: String) {
        lock.lock()
        let active = audioSessionActive
        let wanted = desiredSpeakerOn
        lock.unlock()
        guard active else { return }
        /*
         **先灭再点，不能只补类目。**

         2026-09-18 真机 19:47 三通群视频：类目被打回 `SoloAmbient`，这里补成
         `PlayAndRecord`，回读也确认补上了（`inputs=1`）——然而三十秒里
         `packetsSent=0`、`totalSamplesDuration=0`，**一个采样都没录到**。
         也就是说被打翻的那一下把 libwebrtc 的 VoIP 音频单元拆掉了，
         而它不会因为类目恢复就自己重建：擦桌子救不了灶。

         `isAudioEnabled` 走一遍 false→true 才是重建的手柄（头文件原话：设 NO
         会 stop and uninitialize，设 YES 会在需要时 initialize and start）。
         它要 `useManualAudio = YES` 才生效，那一句在 `applyCallAudioCategory` 里。

         顺序是**先关掉、再配类目、最后打开**：类目还不对的时候点火，
         点起来的也是错的那一路。
        */
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        session.isAudioEnabled = false
        session.unlockForConfiguration()
        applyCallAudioCategory(why: why)
        applySpeakerRoute(wanted)
    }

    private func routeDidChange(_ note: Notification) {
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        lock.lock()
        let wanted = desiredSpeakerOn
        let active = audioSessionActive
        lock.unlock()
        guard active else { return }
        IMRTCLog.info("音频路由变化", ["reason": String(reason), "outputs": outputs.joined(separator: ","),
                                     "speaker": String(wanted)])
        /*
         **兜底：category 被谁踢掉了都补回来。**

         上面那两个通知只盖住「被打断」与「媒体服务重置」两条已知来路；真机上那次
         究竟是谁把会话打回 `SoloAmbient` 还没查清。而 category 一变必然伴随一次
         路由变化（`reason=3` categoryChange），所以在这里加一道无差别的检查——
         **不管是谁干的，发现不是通话态就设回去**，并且喊一声。
         不会自激：设回去之后这个判据就不成立了。
        */
        if AVAudioSession.sharedInstance().category != .playAndRecord {
            IMRTCLog.warn("通话中音频会话被打回非通话类目", [
                "category": AVAudioSession.sharedInstance().category.rawValue,
                "reason": String(reason),
            ])
            reassertCallAudioCategory(why: "路由变化时发现类目不对")
            return
        }
        guard imShouldReapplySpeaker(wantsSpeaker: wanted, reason: reason, outputPorts: outputs) else { return }
        IMRTCLog.info("插拔后系统清掉了外放覆盖，按钮还亮着：补回扬声器", [:])
        applySpeakerRoute(true)
    }

    /// 真正去改路由。**只在会话已经配置过之后调**——`overrideOutputAudioPort` 只有
    /// category 已是 `.playAndRecord` 时才有效，没配就调会静默失效。
    private func applySpeakerRoute(_ on: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            IMRTCLog.warn("切换扬声器失败", ["on": String(on), "err": String(describing: error)])
        }
    }
}
#endif
