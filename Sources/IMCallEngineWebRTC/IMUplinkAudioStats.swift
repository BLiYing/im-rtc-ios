#if canImport(WebRTC) && canImport(UIKit)
import AVFoundation
import Foundation
import WebRTC
import IMCallEngine

/**
 上行音频采样：**回答「对方到底听不听得见我」这一个问题**。

 # 为什么加它

 2026-09-18 真机：frank 说话，alice 全程听不见。服务端侧的判据很硬——
 Pion 的 `上行 Track 已接入` 是**收到第一个 RTP 包**才触发的，而 frank 那通
 只有 `video/H264`，没有 `audio/opus`：**一个音频包都没发出去**。
 与此同时本端日志里**没有任何异常**：`音频路由变化` 照常两条，
 `音频会话配置失败` 一条都没有，`room.mute` 也没发过。

 这正是摄像头黑屏那次的翻版——那次能定位是因为有 `session_running` /
 `inputs` / `outputs` 三个字段（见 `IMCaptureWatch`），而麦克风这条路
 **当时一个观测面都没有**：`上行视频采样` 有二十多个字段，音频零个。

 # 它要分开的三种情形

 | 现象 | 读数 | 结论 |
 |---|---|---|
 | ADM 根本没在录 | `capture.totalSamplesDuration` 不涨、`capture.audioLevel=0` | 音频会话 / 权限的问题 |
 | 录到了但没发 | `audioLevel>0` 而 `packetsSent=0` | 轨道被 mute、或没挂上 sender |
 | 发了但没到 | `packetsSent` 在涨 | 不在本端，去看网络与服务端 |

 所以除了 `outbound-rtp` 还要带上**会话侧的现场**（category / mode / 是否
 active / 有没有输入口），否则第一种情形仍然只能靠猜。

 # 节奏

 挂在「麦克风发布」这一个动作上，`sampleOffsets` 各采一行：+2s 让协商跑完，
 +10s 看它有没有**中途停掉**（后台冻结、被别的 App 抢走，都是这个形态）。
 **一通电话两行**，与 `IMUplinkVideoStats` 同一条取舍（CONVENTIONS §6）。
 挂断时 `cancel()`，两轮不交错。
 */
final class IMUplinkAudioStats: @unchecked Sendable {

    /// 发布麦克风后第几秒各采一行。+2s 等协商跑完，+10s 看有没有中途停掉。
    static let sampleOffsets = [2, 10]

    /// 上行音频（outbound-rtp）要看的字段。缺席的不写（见 `imStatsFields`）。
    ///
    /// `packetsSent` 是这里唯一的硬判据：它不涨就是一个包都没出去，别的字段都只是解释它。
    static let outboundKeys = [
        "packetsSent", "bytesSent", "targetBitrate", "retransmittedPacketsSent",
        "nackCount", "totalPacketSendDelay", "active",
    ]

    /// 采集侧（media-source）。`totalSamplesDuration` 不涨 = ADM 压根没在录。
    static let sourceKeys = ["audioLevel", "totalAudioEnergy", "totalSamplesDuration"]

    private let queue = DispatchQueue(label: "com.imrtc.engine.media.uplink-audio-stats")
    /// 还没到点的采样。**只在 `queue` 上动。**
    private var pending: [DispatchWorkItem] = []

    /// burst 发布麦克风之后按 `sampleOffsets` 采一轮，并取消上一轮还没到点的。
    func burst(_ connection: RTCPeerConnection?) {
        guard let connection else { return }
        queue.async {
            self.cancelPending()
            for offset in Self.sampleOffsets {
                // 弱引用：挂断后 PeerConnection 会被整个换掉，别让一条迟到的采样把旧的留住。
                let item = DispatchWorkItem { [weak connection] in
                    guard let connection else { return }
                    Self.collect(connection, phase: "推麦克风+\(offset)s")
                }
                self.pending.append(item)
                self.queue.asyncAfter(deadline: .now() + .seconds(offset), execute: item)
            }
        }
    }

    /// cancel 取消还没到点的采样（挂断时调）。
    func cancel() {
        queue.async { self.cancelPending() }
    }

    private func cancelPending() {
        pending.forEach { $0.cancel() }
        pending = []
    }

    private static func collect(_ connection: RTCPeerConnection, phase: String) {
        // 会话现场先拍下来：统计回调是异步的，等它回来时路由可能已经又变过了。
        let session = sessionFields()
        connection.statistics { report in
            var fields = ["phase": phase]
            fields.merge(session) { _, new in new }
            for stats in report.statistics.values {
                let audio = stats.values["kind"] as? String == "audio"
                switch stats.type {
                case "outbound-rtp" where audio:
                    fields.merge(imStatsFields(stats.values, keys: Self.outboundKeys)) { _, new in new }
                case "media-source" where audio:
                    fields.merge(imStatsFields(stats.values, keys: Self.sourceKeys,
                                               prefix: "capture.")) { _, new in new }
                default:
                    break
                }
            }
            IMRTCLog.info("上行音频采样", fields)
        }
    }

    /**
     sessionFields 音频会话的现场。

     **读的是 `AVAudioSession.sharedInstance()` 而不是 `RTCAudioSession` 的镜像**：
     后者是 libwebrtc 自己记的账，两边不一致恰恰是要查的东西之一。
     `isAudioEnabled` / `useManualAudio` 仍从 `RTCAudioSession` 取——那两个本来就只有它有，
     而且它们为假时 ADM 直接不录，是「录不到」最常见的一种。
     */
    private static func sessionFields() -> [String: String] {
        let rtc = RTCAudioSession.sharedInstance()
        let av = AVAudioSession.sharedInstance()
        return [
            "session.category": av.category.rawValue,
            "session.mode": av.mode.rawValue,
            "session.inputs": String(av.currentRoute.inputs.count),
            "session.outputs": String(av.currentRoute.outputs.count),
            "session.input_available": String(av.isInputAvailable),
            "session.record_permission": permissionText(av),
            "rtc.is_active": String(rtc.isActive),
            "rtc.audio_enabled": String(rtc.isAudioEnabled),
            "rtc.manual_audio": String(rtc.useManualAudio),
        ]
    }

    /// permissionText 录音权限。iOS 17 起 `recordPermission` 被 `AVAudioApplication` 取代，
    /// 但本仓最低 iOS 15，两条路都得留着。
    private static func permissionText(_ session: AVAudioSession) -> String {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return "granted"
            case .denied: return "denied"
            case .undetermined: return "undetermined"
            @unknown default: return "unknown"
            }
        }
        switch session.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }
}
#endif
