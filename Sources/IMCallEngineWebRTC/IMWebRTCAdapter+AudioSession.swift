#if canImport(WebRTC) && canImport(UIKit)
import Foundation
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
