#if canImport(WebRTC)
import Foundation
import IMCallEngine
import WebRTC

/**
 把 libwebrtc 自己的日志接进 `IMRTCLog`——**只接音频那一小撮**。

 # 为什么

 2026-09-18 视频通话双向无声：音频会话在接通后被反复打回 `SoloAmbient`，
 我们这一侧能看见的只有"被打回了"，看不见 libwebrtc 那一侧在同一时刻做了什么——
 它的 ADM 什么时候 `Configuring audio session for WebRTC`、什么时候
 `Unconfiguring`、音频单元起没起来（`StartRecording failed to start audio unit`）
 全是 `RTCLog`，从来没进过我们的日志。反汇编能看到这些字符串在包里，
 却看不到它们哪一刻被打出来。这条桥就是补这一段。

 # 只接音频

 libwebrtc 的 Info 级日志量很大（ICE、SDP、统计…），全接会把回传日志淹掉。
 这里按关键词只放行音频会话 / ADM / 音频单元那几类，其余丢弃。
 关键词见 `keywords`，改的时候记得它们要盖住 `RTCAudioSession.mm`、
 `audio_device_ios.mm`、`voice_processing_audio_unit.mm`、`audio_engine_device.mm`
 四个文件的日志。

 # 生命周期

 `RTCCallbackLogger` 必须被持有，所以是 static。跟着进程走，不停。
 */
enum IMWebRTCLogBridge {

    private static let logger = RTCCallbackLogger()

    /// 放行的关键词（小写比较）。
    private static let keywords = [
        "audio session", "audiosession", "audio unit", "audioenginedevice",
        "playout", "recording", "webrtc session", "route change", "interrupt",
        "voice processing", "vpio", "canplayorrecord", "audio device",
    ]

    /// 每帧回调都会打的那几条，量大且没信息，即使命中关键词也不要。
    private static let noise = ["ongetplayoutdata", "glitch"]

    private static let started: Void = {
        RTCSetMinDebugLogLevel(.info)
        logger.severity = .info
        logger.start(messageAndSeverityHandler: { message, severity in
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard keywords.contains(where: { lower.contains($0) }),
                  !noise.contains(where: { lower.contains($0) }) else { return }
            switch severity {
            case .warning, .error:
                IMRTCLog.warn("libwebrtc", ["msg": trimmed])
            default:
                IMRTCLog.info("libwebrtc", ["msg": trimmed])
            }
        })
    }()

    /// start 接上。幂等，多次调用只接一次。
    static func start() {
        _ = started
    }
}
#endif
