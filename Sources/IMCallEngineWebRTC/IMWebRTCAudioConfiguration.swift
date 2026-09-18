#if canImport(WebRTC) && os(iOS)
import AVFoundation
import Foundation
import IMCallEngine
import WebRTC

/**
 钉死 libwebrtc 的「WebRTC 需要的音频配置」。**视频通话双向无声的根因修复（2026-09-18）。**

 # 根因

 libwebrtc 的 ADM 开麦时（`AudioDeviceIOS::InitRecording` → `ConfigureAudioSessionLocked`
 → `-[RTCAudioSession configureWebRTCSession:]`）会把音频会话配成
 `+[RTCAudioSessionConfiguration webRTCConfiguration]` 里的那份配置。

 上游 libwebrtc 里这份配置是写死的 `PlayAndRecord / VoiceChat`。**我们用的 webrtc-sdk fork
 不是**：它的 `-[RTCAudioSessionConfiguration init]`（反汇编 `0x250bb0`）读的是
 `AVAudioSession.sharedInstance()` 当下的 `category` / `mode`——**默认值是第一次被碰到那一刻
 会话的快照**。App 启动后会话是系统默认的 `SoloAmbient / Default`，快照要是拍在我们配会话
 之前，整个进程里 WebRTC 每次开麦都会把会话「配」回 `SoloAmbient`：

     20:27:00.859 我们：音频会话已配成通话态 PlayAndRecord
     20:27:00.915 libwebrtc：Configuring audio session for WebRTC.
     20:27:00.918 [Demo 追踪] 有人把音频会话写成非通话类目 SoloAmbient/Default  stack=WebRTC…
     20:27:00.946 libwebrtc：Failed to set category and mode: -50
     20:27:01.003 libwebrtc：InitRecording: InitPlayOrRecord failed for InitRecording!

 麦克风死在最后一行，而会话被打回 `SoloAmbient` 放音也跟着没了——**两个方向同时无声**。
 我们的路由兜底把类目补回去，又触发 ADM 重配、又被打回，就是那「一秒拉锯六轮」。

 # 为什么时好时坏、为什么只在视频通话

 看快照拍在哪一刻：视频通话响铃期要开本端预览，预览先把工厂与 ADM 建起来，
 那时会话还没配（故意的，见 `IMWebRTCAdapter+AudioSession.swift` 头部）→ 快照 = SoloAmbient。
 纯音频通话没有预览，开麦时先配会话后建工厂 → 快照 = PlayAndRecord，**同一进程里之后的视频
 通话也跟着正常**（19:32 纯音频之后 19:36 视频就通了，而每次重装后直接打视频都不通）。

 # 修法

 不依赖快照：在任何 WebRTC 音频对象存在之前（`IMPeerConnections.sharedFactory`）、以及每次
 我们自己配会话时，**显式** `setWebRTCConfiguration(_:)`，值与 `applyCallAudioCategory` 一致。
 这正是这个 fork 的头文件留的口子（`Provide a way to override the default configuration`）。
 */
enum IMWebRTCAudioConfiguration {

    /// install 钉死配置。幂等，可以多次调；每次都整份重设，不读当前会话。
    static func install() {
        let config = RTCAudioSessionConfiguration()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.allowBluetooth]
        // 下面三项同样是快照来的，一并钉住。取值与 20:27 日志里 ADM 实际用的一致
        // （Set preferred sample rate to 48000 / IO buffer duration 0.02 / 单声道）。
        config.sampleRate = 48_000
        config.ioBufferDuration = 0.02
        config.inputNumberOfChannels = 1
        config.outputNumberOfChannels = 1
        RTCAudioSessionConfiguration.setWebRTC(config)
    }

    /// current 读回当前生效的那份，给日志用：`category` 不是 PlayAndRecord 就说明又被快照顶掉了。
    static func current() -> (category: String, mode: String) {
        let config = RTCAudioSessionConfiguration.webRTC()
        return (config.category, config.mode)
    }
}
#endif
